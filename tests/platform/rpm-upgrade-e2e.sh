#!/usr/bin/env bash
set -u
# ^ external runs as a non-root user with sudo in a Rocky or Fedora container; every step is real (dnf, make, sudo, downloads); argument rocky or fedora
# ^ security the fake credential is built at runtime from fragments and never printed; the output is checked for its absence before any of it is shown

DISTRO="${1:-}"
CK="$HOME/checkout"
GSG="$CK/bin/git-secret-guard"
OUTF="$HOME/e2e.out"
NAMES=(git git-receive-pack git-shell git-upload-archive git-upload-pack scalar)
pass=0
fail=0
RC=0
OUT=""
PKG_BEFORE="" SUMS_BEFORE=""

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
# ^ why the probe repository alone, not every enabled one; unrelated mirror skew failed a run once with no code change
dnf_update_probe() { run sudo dnf --assumeno --disablerepo='*' --enablerepo=gsgprobe update; }
# ^ invariant true when a Problem line or the package line under it names git or perl-Git; a Problem about other packages (mirror skew) does not count
git_problem_in_output() { printf '%s\n' "$OUT" | grep -Eq '^([[:space:]]*Problem|[[:space:]]+- ).*(git|perl-Git)'; }
fake_key() { printf '%s%s' "AKI""A" "Q7XK2MWB4HZ5NR3T"; }
git_ver() { "$1" --version | sed 's/^git version //'; }
ver_ge_254() {
    local v
    v="$(git_ver "$1")" || return 1
    [[ $v =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    [ "${BASH_REMATCH[1]}" -gt 2 ] || { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -ge 54 ]; }
}
usrbin_sums() { (cd /usr/bin && sha256sum "${NAMES[@]}"); }
rpm_clean() { [ -z "$(rpm -V git-core 2>&1)" ]; }
LINKS_BEFORE=""
E2E_POLL_STEP=0.2 E2E_POLL_TICKS=600 E2E_STALL_SECONDS=60

# ^ invariant e2e_poll CMD... runs CMD at most E2E_POLL_TICKS times, E2E_POLL_STEP seconds apart; rc 0 as soon as CMD succeeds
e2e_poll() {
    local n
    for ((n = 0; n < E2E_POLL_TICKS; n++)); do
        if "$@"; then return 0; fi
        sleep "$E2E_POLL_STEP"
    done
    return 1
}

usrbin_links() { (cd /usr/bin && stat -c '%N' "${NAMES[@]}"); }

# ^ security the wrapper is root-owned in a root-owned directory; the fixed system path accepts it; it stalls one chosen call, else runs the real sudo
stall_wrapper() {
    local tmp rc
    tmp="$(mktemp)" || return 1
    if ! cat >"$tmp" <<EOF; then
#!/bin/sh
if [ -f /tmp/gsg-stall.text ]; then
    case " \$* " in
        *"\$(cat /tmp/gsg-stall.text)"*)
            skip="\$(cat /tmp/gsg-stall.skip 2>/dev/null || echo 0)"
            if [ "\$skip" -gt 0 ]; then
                echo \$((skip - 1)) >/tmp/gsg-stall.skip
            else
                rm -f /tmp/gsg-stall.text /tmp/gsg-stall.skip
                : >/tmp/gsg-stalled
                exec sleep $E2E_STALL_SECONDS
            fi
            ;;
    esac
fi
exec /usr/bin/sudo "\$@"
EOF
        rm -f "$tmp"
        return 1
    fi
    sudo mkdir -p /usr/local/libexec/gsg-test && sudo install -o root -g root -m 755 "$tmp" /usr/local/libexec/gsg-test/sudo
    rc=$?
    rm -f "$tmp"
    return "$rc"
}

# ^ security only the session this function started is signalled; setsid makes the child its own group leader; kill -SIG -- -PID reaches its group only
# ^ invariant interrupt_run TEXT SKIP SIGNAL CMD... stalls privileged call SKIP+1 holding TEXT, sends SIGNAL, waits; OUT = what CMD printed
interrupt_run() {
    local text="$1" skip="$2" sig="$3" pid
    shift 3
    if ! printf '%s' "$text" >/tmp/gsg-stall.text || ! printf '%s' "$skip" >/tmp/gsg-stall.skip; then return 1; fi
    rm -f /tmp/gsg-stalled
    (GSG_GITUP_BUILD_PATH="/usr/local/libexec/gsg-test:/usr/bin:/bin" setsid env --default-signal=INT "$@" >"$OUTF" 2>&1 </dev/null & echo $! >"$HOME/int.pid")
    pid="$(<"$HOME/int.pid")"
    if [[ ! $pid =~ ^[0-9]+$ ]]; then return 1; fi
    if ! e2e_poll test -e /tmp/gsg-stalled; then
        kill -KILL -- "-$pid" 2>/dev/null
        return 1
    fi
    if ! kill "-$sig" -- "-$pid"; then
        kill -KILL -- "-$pid" 2>/dev/null
        return 1
    fi
    if ! e2e_poll not kill -0 "$pid" 2>/dev/null; then
        kill -KILL -- "-$pid" 2>/dev/null
        return 1
    fi
    OUT="$(<"$OUTF")"
}

cleanup() {
    sudo rm -rf /usr/bin/.scalar.gsg-new
    sudo rm -f /etc/yum.repos.d/gsgprobe.repo
}
trap cleanup EXIT

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

upload_pack_runs() {
    local d rc
    d="$(mktemp -d)" || return 1
    git init -q "$d" && "$1" --stateless-rpc --advertise-refs "$d" >/dev/null
    rc=$?
    rm -rf -- "$d"
    return "$rc"
}

# ^ invariant a local repository whose git packages (2.99.0) are newer than any real one, to see what dnf update does with and without the exclusion
fake_repo() {
    local p req dir="$HOME/rpmbuild/SPECS"
    mkdir -p "$dir" "$HOME/fakerepo" || return 1
    for p in git-core git git-core-doc perl-Git; do
        req=""
        case "$p" in git | git-core-doc) req="Requires: git-core = 2.99.0-1" ;; esac
        if [ "$p" = perl-Git ]; then req="Requires: git = 2.99.0-1"; fi
        printf 'Name: %s\nVersion: 2.99.0\nRelease: 1\nSummary: probe %s\nLicense: MIT\n%s\nBuildArch: noarch\n%%description\nprobe\n%%install\nmkdir -p %%{buildroot}/usr/share/gsgprobe\necho %s > %%{buildroot}/usr/share/gsgprobe/%s\n%%files\n/usr/share/gsgprobe/%s\n' \
            "$p" "$p" "$req" "$p" "$p" "$p" >"$dir/$p.spec" || return 1
        rpmbuild -bb "$dir/$p.spec" >/dev/null 2>&1 || return 1
    done
    cp "$HOME"/rpmbuild/RPMS/noarch/*.rpm "$HOME/fakerepo/" || return 1
    createrepo_c "$HOME/fakerepo" >/dev/null 2>&1 || return 1
    printf '[gsgprobe]\nname=gsgprobe\nbaseurl=file://%s\nenabled=1\ngpgcheck=0\n' "$HOME/fakerepo" | sudo tee /etc/yum.repos.d/gsgprobe.repo >/dev/null
}

rocky_upgrade() {
    printf '== Rocky: stock RPM git, then install --upgrade-git (source route)\n'
    show "$(git --version) from $(command -v git); $(rpm -q git-core)"
    check "the machine starts with the stock RPM git, older than 2.54" not ver_ge_254 "$(command -v git)"
    PKG_BEFORE="$(rpm -q git-core)"
    SUMS_BEFORE="$(usrbin_sums)"
    LINKS_BEFORE="$(usrbin_links)"
    check "rpm -V git-core is clean before anything" rpm_clean
    run "$GSG" install </dev/null
    check "install without the flag and without a terminal refuses" rc_is 1
    check "and names --upgrade-git" has "--upgrade-git"
    check "and says nothing was changed" has "nothing was changed"
    check "and no ~/.gitconfig was created by the write probe" test ! -e "$HOME/.gitconfig"
    check "and /usr/local/bin/git does not exist" test ! -e /usr/local/bin/git
    # ^ invariant the build starts without perl-interpreter => the plan installs it and the source builds with it, never with the perl metapackage
    # ^ why rpm -e --nodeps, not dnf remove; dnf remove took the stock git-core out with perl-interpreter (run 42358458414), and the later checks need it
    show "required by: $(rpm -q --whatrequires perl-interpreter 2>&1 | head -n 8 | tr '\n' ' ')"
    if rpm -q perl-interpreter >/dev/null 2>&1; then sudo rpm -e --nodeps perl-interpreter >/dev/null 2>&1 || true; fi
    show "before the build: $(rpm -q perl-interpreter 2>&1 | head -n 1); $(rpm -q perl 2>&1 | head -n 1)"
    check "perl-interpreter is not installed before the build" not rpm -q perl-interpreter
    # shellcheck disable=SC2016
    check "and the stock git-core is still the same version, rpm -V clean" bash -c '[ "$(rpm -q git-core)" = "$1" ] && [ -z "$(rpm -V git-core 2>&1)" ]' _ "$PKG_BEFORE"
    run "$GSG" install --upgrade-git </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'route:|building git|now; continuing|installed git-secret-guard' | head -n 6)"
    check "install --upgrade-git ends with exit 0" rc_is 0
    check "the plan named the source route" has "route: source"
    check "the plan named the pinned version" has "download git 2.56.0"
    show "$(printf '%s' "$OUT" | grep -E '^  as root: ' | cut -c1-110)"
    check "every privileged command in the plan starts with an absolute path" test -z "$(printf '%s\n' "$OUT" | grep -E '^  as root: [^/]')"
    check "and the plan names mkdir" has "as root: /usr/bin/mkdir"
    check "/usr/local/bin/git is new enough" ver_ge_254 /usr/local/bin/git
    show "$(printf '%s' "$OUT" | grep -E 'dnf may upgrade|dry run' | cut -c1-200)"
    # shellcheck disable=SC2016
    check "the plan installs perl-interpreter and not the perl metapackage" bash -c '[[ $1 == *" perl-interpreter "* && $1 != *" perl "* ]]' _ "$OUT"
    check "and warns that dnf may upgrade installed packages" has "dnf may upgrade packages that are already installed"
    check "the build, made without the perl metapackage, ran: perl-interpreter is installed and can load ExtUtils::MakeMaker" bash -c 'rpm -q perl-interpreter >/dev/null && perl -MExtUtils::MakeMaker -e 1'
    show "perl metapackage afterwards: $(rpm -q perl 2>&1 | head -n 1)"
    show "$(/usr/local/bin/git --version); PATH git: $(command -v git)"
    check "it comes first on PATH" test "$(command -v git)" = /usr/local/bin/git
    check "the RPM git-core is the same version" test "$(rpm -q git-core)" = "$PKG_BEFORE"
    check "rpm -V git-core reports nothing" rpm_clean
    check "/usr/bin is untouched" test "$(usrbin_sums)" = "$SUMS_BEFORE"
    check "no build directory is left in /tmp" test -z "$(find /tmp -maxdepth 1 -name 'gsg-git-build.*' | head -n 1)"
    check "a commit with a fake key is blocked and a clean one passes" blocked_commit git
    run "$GSG" install --upgrade-git </dev/null
    check "a rerun exits 0" rc_is 0
    check "a rerun prints no plan" not has "upgrade plan"
}

rocky_takeover() {
    printf '== Rocky: system git takeover\n'
    cp /etc/dnf/dnf.conf "$HOME/dnf.conf.before"
    run "$GSG" install </dev/null
    check "install alone offers the takeover" has "--take-over-system-git"
    check "and /usr/bin/git is still the RPM file" test "$(usrbin_sums)" = "$SUMS_BEFORE"
    if fake_repo; then ok "a local repository with git packages 2.99.0 is set up"; else bad "the local repository could not be built"; fi
    dnf_update_probe
    check "control: before the takeover dnf update would upgrade git-core" has "git-core"
    run "$GSG" install --take-over-system-git </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'dnf stops|pin bump|rpm -V will|restore-system-git|now point' | head -n 6)"
    check "install --take-over-system-git exits 0" rc_is 0
    check "/usr/sbin/restorecon exists (policycoreutils)" test -x /usr/sbin/restorecon
    check "the takeover found restorecon in the system path, no warning" not has "restorecon was not found"
    check "the plan stated its cost" has "dnf stops updating git"
    check "the takeover plan has a heading" has "system git takeover plan"
    check "every privileged command in the takeover plan starts with an absolute path" test -z "$(printf '%s\n' "$OUT" | grep -E '^  as root: [^/]')"
    check "the plan names restorecon of dnf.conf" has "as root: /usr/sbin/restorecon -- /etc/dnf/dnf.conf"
    check "and the removal of the old backup directory" has "rm -rf -- /var/lib/git-secret-guard/system-git/orig.old"
    check "/usr/bin/git is a symlink to /usr/local/bin/git" test "$(readlink /usr/bin/git)" = /usr/local/bin/git
    show "$(/usr/bin/git --version); $(grep -E '^excludepkgs=' /etc/dnf/dnf.conf)"
    check "/usr/bin/git is new enough" ver_ge_254 /usr/bin/git
    check "dnf.conf has the excludepkgs entry for the four packages" grep -q '^excludepkgs=git git-core git-core-doc perl-Git$' /etc/dnf/dnf.conf
    check "the RPM is still installed at the same version" test "$(rpm -q git-core)" = "$PKG_BEFORE"
    check "a commit with a fake key through /usr/bin/git by full path is blocked" blocked_commit /usr/bin/git
    check "git-upload-pack runs through /usr/bin" upload_pack_runs /usr/bin/git-upload-pack
    run rpm -V git-core
    check "rpm -V now reports the taken-over files, as documented" has "/usr/bin/git"
}

rocky_takeover_dnf() {
    printf '== Rocky: dnf update, rerun, status, uninstall with the takeover active\n'
    dnf_update_probe
    show "$(printf '%s' "$OUT" | grep -E 'git|Problem|Transaction Summary|Nothing' | head -n 5)"
    check "dnf update no longer offers git-core" not has "git-core"
    check "and reports no problem that names git or perl-Git" not git_problem_in_output
    # shellcheck disable=SC2016
    check "the probe repository update ends in a transaction summary or nothing to do" bash -c '[[ $1 == *"Transaction Summary"* || $1 == *"Nothing to do"* ]]' _ "$OUT"
    check "/usr/bin/git still points at /usr/local/bin after dnf update" test "$(readlink /usr/bin/git)" = /usr/local/bin/git
    run sudo dnf --assumeno update
    show "dnf update over every enabled repository (not a check, mirrors can be out of step): $(printf '%s' "$OUT" | grep -E 'Problem|Transaction Summary|Nothing to do' | head -n 2 | tr '\n' ' ')"
    run "$GSG" install --take-over-system-git </dev/null
    check "a second takeover changes nothing and says so" has "nothing to take over"
    run "$GSG" status
    show "$(printf '%s' "$OUT" | grep -i 'takeover')"
    check "status reports the active takeover" has "system git takeover: active"
    run "$GSG" uninstall </dev/null
    check "uninstall stops while the takeover is active" rc_is 1
    check "and names restore-system-git" has "restore-system-git"
}

rocky_restore() {
    printf '== Rocky: restore-system-git, a failing takeover, rollback\n'
    run "$GSG" restore-system-git </dev/null
    show "$OUT"
    check "restore-system-git exits 0" rc_is 0
    check "the six RPM files are back, byte for byte" test "$(usrbin_sums)" = "$SUMS_BEFORE"
    check "rpm -V git-core is clean again" rpm_clean
    check "dnf.conf is as it was" cmp -s "$HOME/dnf.conf.before" /etc/dnf/dnf.conf
    check "the backup directory is gone" test ! -e /var/lib/git-secret-guard/system-git
    run "$GSG" restore-system-git </dev/null
    check "a second restore says nothing to restore" has "nothing to restore"
    check "and exits 0" rc_is 0
    sudo mkdir /usr/bin/.scalar.gsg-new
    run "$GSG" install --take-over-system-git </dev/null
    sudo rm -rf /usr/bin/.scalar.gsg-new
    show "$(printf '%s' "$OUT" | grep -E 'failed|every original' | head -n 4)"
    check "a takeover whose sixth swap fails (after five links were swapped) exits 1" rc_is 1
    check "and puts every original back" has "every original is back"
    check "the six RPM files are byte for byte the same after the rollback" test "$(usrbin_sums)" = "$SUMS_BEFORE"
    check "rpm -V git-core is clean after the rollback" rpm_clean
    check "dnf.conf is as it was after the rollback" cmp -s "$HOME/dnf.conf.before" /etc/dnf/dnf.conf
    check "no backup directory is left after the rollback" test ! -e /var/lib/git-secret-guard/system-git
    check "git works throughout" test -n "$(/usr/bin/git --version)"
}

orig_ids() {
    local f
    for f in /var/lib/git-secret-guard/system-git/orig/*; do
        if [ -L "$f" ]; then printf '%s -> %s\n' "${f##*/}" "$(readlink "$f")"; else printf '%s %s\n' "${f##*/}" "$(sha256sum <"$f")"; fi
    done
}

rocky_interrupts() {
    local ids before="$HOME/dnf.conf.before"
    printf '== Rocky: interrupted takeover, interrupted restore, killed takeover (real sudo, real signals)\n'
    check "the stall wrapper is installed as a root-owned file" stall_wrapper
    check "the machine is clean before the interrupts" rpm_clean
    interrupt_run '.scalar.gsg-new' 1 INT "$GSG" install --take-over-system-git
    show "$(printf '%s' "$OUT" | grep -E 'putting everything back|every original|interrupted' | head -n 4)"
    check "an interrupt at the sixth swap rolls back from the signal handler" has "putting everything back"
    check "the six RPM files are the same after the rolled back takeover" test "$(usrbin_sums)" = "$SUMS_BEFORE"
    check "and they are the same links" test "$(usrbin_links)" = "$LINKS_BEFORE"
    check "rpm -V git-core is clean after it" rpm_clean
    check "dnf.conf is as it was after it" cmp -s "$before" /etc/dnf/dnf.conf
    check "no backup directory after it" test ! -e /var/lib/git-secret-guard/system-git
    run "$GSG" install --take-over-system-git </dev/null
    check "a takeover for the restore interrupt exits 0" rc_is 0
    ids="$(orig_ids)"
    TMPS_BEFORE="$(find /tmp -maxdepth 1 -name 'tmp.*' | wc -l)"
    interrupt_run '.git-shell.gsg-restore' 1 INT "$GSG" restore-system-git
    show "$(printf '%s' "$OUT" | grep -E 'interrupted|run:' | head -n 3)"
    check "a stopped restore says it was interrupted" has "restore-system-git was interrupted"
    check "and names the command to run next" has "restore-system-git (it can be repeated"
    check "and leaves no /tmp/tmp.* directory behind" test "$(find /tmp -maxdepth 1 -name 'tmp.*' | wc -l)" = "$TMPS_BEFORE"
    run "$GSG" status
    show "$(printf '%s' "$OUT" | grep -i takeover)"
    check "status names the fix for the half-restored machine" has "install --take-over-system-git"
    check "and, for someone undoing it, restore-system-git" has "restore-system-git"
    run "$GSG" install --take-over-system-git </dev/null
    check "following that advice leaves the saved originals as they were" test "$(orig_ids)" = "$ids"
    run "$GSG" restore-system-git </dev/null
    check "the final restore exits 0" rc_is 0
    check "the six RPM files are back byte for byte" test "$(usrbin_sums)" = "$SUMS_BEFORE"
    check "and as the same links" test "$(usrbin_links)" = "$LINKS_BEFORE"
    check "rpm -V git-core is clean after the interrupted restore" rpm_clean
    check "dnf.conf is as it was after it" cmp -s "$before" /etc/dnf/dnf.conf
    check "no backup directory after it" test ! -e /var/lib/git-secret-guard/system-git
    interrupt_run 'cp -a' 1 KILL "$GSG" install --take-over-system-git
    check "a killed takeover leaves exactly one dnf marker" test "$(grep -c 'git-secret-guard: takeover' /etc/dnf/dnf.conf)" = 1
    check "and no record" test ! -e /var/lib/git-secret-guard/system-git/record
    run "$GSG" install --take-over-system-git </dev/null
    check "the next run finishes the takeover" rc_is 0
    check "with still exactly one marker" test "$(grep -c 'git-secret-guard: takeover' /etc/dnf/dnf.conf)" = 1
    check "and /usr/bin/git is our link" test "$(readlink /usr/bin/git)" = /usr/local/bin/git
    run "$GSG" restore-system-git </dev/null
    check "restore after the killed takeover exits 0" rc_is 0
    check "the six RPM files are back as the same links" test "$(usrbin_links)" = "$LINKS_BEFORE"
    check "rpm -V git-core is clean at the end" rpm_clean
    check "dnf.conf is as it was at the end" cmp -s "$before" /etc/dnf/dnf.conf
    sudo rm -rf /usr/local/libexec/gsg-test /tmp/gsg-stall.text /tmp/gsg-stall.skip /tmp/gsg-stalled
}

fedora_package() {
    printf '== Fedora: no git installed, install --upgrade-git (package route)\n'
    check "the machine starts with no git" not command -v git
    run "$GSG" install </dev/null
    check "install without the flag and without a terminal refuses" rc_is 1
    check "and names --upgrade-git" has "--upgrade-git"
    run "$GSG" install --upgrade-git </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'route:|now; continuing|installed git-secret-guard|neither' | head -n 6)"
    check "install --upgrade-git ends with exit 0" rc_is 0
    check "the plan named the package route" has "route: package"
    check "no source build ran" not has "building git"
    check "git is now installed and new enough" ver_ge_254 "$(command -v git)"
    show "$(git --version) from $(command -v git); $(rpm -q git-core)"
    check "git comes from the package, in /usr/bin" test "$(command -v git)" = /usr/bin/git
    check "nothing was built into /usr/local" test ! -e /usr/local/bin/git
    check "a commit with a fake key is blocked and a clean one passes" blocked_commit git
    run "$GSG" install --upgrade-git </dev/null
    check "a rerun exits 0" rc_is 0
    check "a rerun prints no plan" not has "upgrade plan"
    run "$GSG" install --take-over-system-git </dev/null
    check "the takeover has nothing to do on the package route" has "nothing to take over"
}

# ^ coupled sourced by rpm-more-e2e.sh, a reuse of these functions; main runs only when this file is executed
e2e_summary() {
    printf 'E2E SUMMARY: %s passed, %s failed\n' "$pass" "$fail"
    [ "$fail" -eq 0 ]
}

main() {
    case "$DISTRO" in
        rocky)
            rocky_upgrade
            rocky_takeover
            rocky_takeover_dnf
            rocky_restore
            rocky_interrupts
            ;;
        fedora) fedora_package ;;
        *)
            printf 'usage: rpm-upgrade-e2e.sh rocky|fedora\n' >&2
            exit 2
            ;;
    esac
    e2e_summary
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then main; fi
