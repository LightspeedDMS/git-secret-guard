#!/usr/bin/env bash
set -u
# ^ external runs as a non-root user with sudo in an Ubuntu or Debian container; every step is real; arguments ID VERSION_ID
# ^ security the fake credential is built at runtime from fragments and never printed; the output is checked for its absence before any of it is shown
# ^ external not run by the author of this file (no container runtime on the development host); the first real run may need its expectations adjusted

DISTRO="${1:-}"
OSVER="${2:-}"
CK="$HOME/checkout"
GSG="$CK/bin/git-secret-guard"
OUTF="$HOME/e2e.out"
pass=0
fail=0
RC=0
OUT=""

ok() {
    printf 'ok      %s\n' "$1"
    pass=$((pass + 1))
}
bad() {
    printf 'FAIL    %s\n' "$1"
    fail=$((fail + 1))
}
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
not() { ! "$@"; }
run() {
    "$@" >"$OUTF" 2>&1
    RC=$?
    OUT="$(<"$OUTF")"
}
show() { printf '        | %s\n' "$@"; }
has() { [[ $OUT == *"$1"* ]]; }
rc_is() { [ "$RC" -eq "$1" ]; }
fake_key() { printf '%s%s' "AKI""A" "Q7XK2MWB4HZ5NR3T"; }
ver_ge_254() {
    local v
    v="$("$1" --version | sed 's/^git version //')" || return 1
    [[ $v =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    [ "${BASH_REMATCH[1]}" -gt 2 ] || { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -ge 54 ]; }
}

# ^ invariant sets RC and OUT of a commit in a fresh repo holding content $3; rc 1 when the repo cannot be prepared (nothing is judged)
probe_commit() {
    local g="$1" d="$2" content="$3"
    "$g" init -q "$d" && "$g" -C "$d" config user.name gsg && "$g" -C "$d" config user.email gsg@example.invalid || return 1
    printf '%s\n' "$content" >"$d/a.txt" || return 1
    "$g" -C "$d" add a.txt || return 1
    run "$g" -C "$d" commit -q -m probe
}

# ^ invariant the commit holding the fake key is blocked with the hook's own finding line and does not echo the key; a clean commit passes
blocked_commit() {
    local g="$1" d key rc leaked=0 found=0 clean_rc
    d="$(mktemp -d)" || return 1
    key="$(fake_key)"
    probe_commit "$g" "$d" "aws_access_key_id = $key" || {
        rm -rf -- "$d"
        return 1
    }
    rc="$RC"
    if [[ $OUT == *"$key"* ]]; then leaked=1; fi
    if [[ $OUT == *"potential secret(s) in lines this commit adds"* ]]; then found=1; fi
    if [ "$leaked" -eq 0 ]; then show "$(printf '%s' "$OUT" | head -n 3)"; fi
    rm -rf -- "$d"
    d="$(mktemp -d)" || return 1
    probe_commit "$g" "$d" "clean content" || {
        rm -rf -- "$d"
        return 1
    }
    clean_rc="$RC"
    rm -rf -- "$d"
    [ "$rc" -ne 0 ] && [ "$found" -eq 1 ] && [ "$leaked" -eq 0 ] && [ "$clean_rc" -eq 0 ]
}

lists_empty() { test -z "$(find /var/lib/apt/lists -type f ! -name lock | head -n 1)"; }
git_pkg_version() { dpkg-query -W -f='${Version}' git; }
pkg_changed() { [ "$(git_pkg_version)" != "$git_pkg_version_before" ]; }
all_plan_lines_absolute() { test -z "$(printf '%s\n' "$OUT" | grep -E '^  as root: [^/]')"; }
refused_with_nothing_changed() {
    run "$GSG" install </dev/null
    check "install without the flag and without a terminal refuses" rc_is 1
    check "and names --upgrade-git" has "--upgrade-git"
    check "and says nothing was changed" has "nothing was changed"
    check "and no ~/.gitconfig was created by the write probe" test ! -e "$HOME/.gitconfig"
    check "and no git-core PPA file exists" test -z "$(find /etc/apt -name 'git-core-ubuntu-ppa*' 2>/dev/null | head -n 1)"
    check "and /usr/local/bin/git does not exist" test ! -e /usr/local/bin/git
}

ubuntu_expected_form() {
    case "$OSVER" in
        22.04) printf 'list' ;;
        *) printf 'sources' ;;
    esac
}

ubuntu_ppa() {
    local form
    form="$(ubuntu_expected_form)"
    printf '== Ubuntu %s: stock git, then install --upgrade-git (PPA route, %s form)\n' "$OSVER" "$form"
    show "$(git --version) from $(command -v git); package $(git_pkg_version)"
    check "the machine starts with the stock git, older than 2.54" not ver_ge_254 "$(command -v git)"
    check "and add-apt-repository is not installed (the plan must add software-properties-common)" test -z "$(command -v add-apt-repository)"
    check "the apt package lists are empty, as on a fresh image (the product must refresh them itself)" lists_empty
    refused_with_nothing_changed
    run "$GSG" install --upgrade-git </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'route:|PPA|now; continuing|installed git-secret-guard' | cut -c1-160 | head -n 8)"
    check "install --upgrade-git ends with exit 0" rc_is 0
    check "the plan named the PPA route" has "route: ppa"
    check "the plan named the PPA" has "ppa:git-core/ppa"
    check "the plan named the pinned key fingerprint" has "F911AB184317630C59970973E363C90F8F1B6217"
    check "the plan added software-properties-common" has "software-properties-common gnupg"
    show "$(printf '%s' "$OUT" | grep -E '^  as root: ' | cut -c1-140)"
    check "every privileged command in the plan starts with an absolute path" all_plan_lines_absolute
    if [ "$form" = list ]; then
        check "the PPA is a .list file (the older add-apt-repository form)" test -n "$(find /etc/apt/sources.list.d -name 'git-core-ubuntu-ppa-*.list' | head -n 1)"
        check "its key is in trusted.gpg.d" test -f /etc/apt/trusted.gpg.d/git-core-ubuntu-ppa.gpg
    else
        check "the PPA is a .sources file with the key embedded" test -n "$(find /etc/apt/sources.list.d -name 'git-core-ubuntu-ppa-*.sources' | head -n 1)"
    fi
    check "/usr/bin/git is new enough" ver_ge_254 /usr/bin/git
    show "$(git --version) from $(command -v git); package $(git_pkg_version)"
    check "git comes from the package, in /usr/bin" test "$(command -v git)" = /usr/bin/git
    check "the installed package version changed (the PPA's build replaced the stock one)" pkg_changed
    check "apt-cache policy names the PPA" bash -c 'LC_ALL=C apt-cache policy git | grep -q ppa.launchpadcontent.net'
    check "nothing was built into /usr/local" test ! -e /usr/local/bin/git
    check "no warning about another old git" not has "ignores config-based hooks"
    check "no build directory is left in /tmp" test -z "$(find /tmp -maxdepth 1 -name 'gsg-git-build.*' | head -n 1)"
    check "a commit with a fake key is blocked and a clean one passes" blocked_commit git
    run "$GSG" install --upgrade-git </dev/null
    check "a rerun exits 0" rc_is 0
    check "a rerun prints no plan" not has "upgrade plan"
    run "$GSG" uninstall </dev/null
    check "uninstall exits 0" rc_is 0
}

debian_source() {
    printf '== Debian %s: stock git, then install --upgrade-git (pinned source build, no PPA)\n' "$OSVER"
    show "$(git --version) from $(command -v git); package $(git_pkg_version)"
    check "the machine starts with the stock git, older than 2.54" not ver_ge_254 "$(command -v git)"
    check "the apt package lists are empty, as on a fresh image (the product must refresh them itself)" lists_empty
    refused_with_nothing_changed
    run "$GSG" install --upgrade-git </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'route:|building git|now; continuing|installed git-secret-guard' | cut -c1-160 | head -n 6)"
    check "install --upgrade-git ends with exit 0" rc_is 0
    check "the plan named the source route" has "route: source"
    check "the plan named the pinned version" has "download git 2.56.0"
    check "no PPA was attempted" not has "ppa:git-core"
    show "$(printf '%s' "$OUT" | grep -E '^  as root: ' | cut -c1-140)"
    check "every privileged command in the plan starts with an absolute path" all_plan_lines_absolute
    check "/usr/local/bin/git is new enough" ver_ge_254 /usr/local/bin/git
    check "it comes first on PATH" test "$(command -v git)" = /usr/local/bin/git
    check "the distribution package is untouched" test "$(git_pkg_version)" = "$git_pkg_version_before"
    check "no build directory is left in /tmp" test -z "$(find /tmp -maxdepth 1 -name 'gsg-git-build.*' | head -n 1)"
    check "a commit with a fake key is blocked and a clean one passes" blocked_commit git
    run "$GSG" install --upgrade-git </dev/null
    check "a rerun exits 0" rc_is 0
    check "a rerun prints no plan" not has "upgrade plan"
    run "$GSG" uninstall </dev/null
    check "uninstall exits 0" rc_is 0
}

git_pkg_version_before="$(git_pkg_version)"
case "$DISTRO" in
    ubuntu) ubuntu_ppa ;;
    debian) debian_source ;;
    *)
        printf 'usage: apt-upgrade-e2e.sh ubuntu|debian VERSION_ID\n' >&2
        exit 2
        ;;
esac
printf 'E2E SUMMARY: %s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
