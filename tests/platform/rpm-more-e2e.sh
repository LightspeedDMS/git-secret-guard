#!/usr/bin/env bash
set -u
# ^ external the arrangements of the git upgrade E2E missing from rpm-upgrade-e2e.sh (#40); arguments rocky|fedora and MODE
# ^ coupled uses the helpers and the Rocky steps of rpm-upgrade-e2e.sh, sourced above; the modes are named by the phases of rpm-phase.sh
# ^ security the fake credential comes from fake_key there and is never printed; the sudo password is read from a file and never printed

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
# shellcheck source=tests/platform/rpm-upgrade-e2e.sh
source "$HERE/rpm-upgrade-e2e.sh" || exit 2
MODE="${2:-}"
STATE_FILE="$HOME/offline.state"
# ^ external the older of the two pins the bump starts from; digests from kernel.org's sha256sums.asc over HTTPS, 2026-11-06
BUMP_OLD_VERSION=2.55.0
BUMP_OLD_SHA=457fdb04dc8728e007d4688695e6912e6f680727920f2a40bf11eacc17505357
BUMP_OLD_MAN_SHA=a32d432f80df46a14a05d1104c72d5a13fe27e9feba9aa0f017e54131db6b982
PTY_STEP=0.5 PTY_TICKS=3600

# ^ invariant root has no sudo in the root mode; the helpers of the Rocky steps call sudo, and this function runs their argument directly
root_sudo_shim() {
    sudo() { "$@"; }
}

# ^ invariant pty_session OUT ANSWER CMD sets PTY_RC; runs CMD on a pty (script), answers y to each [y/N] and ANSWER to each sudo password prompt, bounded
# ^ security the answers are written only after their prompt has appeared in the transcript; sudo switches echo off for the password
pty_session() {
    local out="$1" answer="$2" cmd="$3" fifo spid tick text asked=0 passed=0 seen_y seen_pw
    fifo="$(mktemp -u)" || return 1
    mkfifo "$fifo" || return 1
    : >"$out" || return 1
    script -qefc "$cmd" "$out" <"$fifo" >/dev/null 2>&1 &
    spid=$!
    exec 7>"$fifo"
    for ((tick = 0; tick < PTY_TICKS; tick++)); do
        if ! kill -0 "$spid" 2>/dev/null; then break; fi
        text="$(<"$out")"
        seen_y="$(printf '%s' "$text" | grep -o '\[y/N\]' | wc -l)"
        seen_pw="$(printf '%s' "$text" | grep -o 'password for' | wc -l)"
        if [ "$seen_y" -gt "$asked" ]; then
            printf 'y\n' >&7
            asked="$seen_y"
        fi
        if [ "$seen_pw" -gt "$passed" ]; then
            printf '%s\n' "$answer" >&7
            passed="$seen_pw"
        fi
        sleep "$PTY_STEP"
    done
    if kill -0 "$spid" 2>/dev/null; then
        kill -KILL "$spid" 2>/dev/null
        PTY_RC=124
    else
        wait "$spid"
        PTY_RC=$?
    fi
    exec 7>&-
    rm -f "$fifo"
    PTY_ASKED="$asked" PTY_PASSWORDS="$passed"
    OUT="$(<"$out")"
    return 0
}

mode_root() {
    root_sudo_shim
    printf '== Rocky as root: the full flow with no sudo on the machine\n'
    check "this is a root run" test "$(id -u)" -eq 0
    check "there is no sudo on the machine" not type -P sudo
    rocky_upgrade
    check "the install named no missing sudo" not has "neither root nor sudo"
    rocky_takeover
    rocky_takeover_dnf
    rocky_restore
}

mode_password() {
    local pw wrong="not-the-password-$RANDOM-$RANDOM"
    printf '== Rocky: sudo with a real password prompt on a pty\n'
    pw="$(<"$HOME/.sudo-pw")"
    check "the password file holds a password" test "${#pw}" -ge 20
    check "sudo asks for a password, none is cached" not sudo -n true
    check "script (a pty) is installed" command -v script
    check "the machine starts with the stock RPM git" not ver_ge_254 "$(command -v git)"
    pty_session "$HOME/pty-wrong.out" "$wrong" "$GSG install"
    show "$(printf '%s' "$OUT" | tr -d '\r' | grep -E 'Upgrade git|password|incorrect|nothing was|sudo' | head -n 6 | cut -c1-160)"
    check "the consent question was asked on the terminal" test "$PTY_ASKED" -ge 1
    check "sudo asked for a password" test "$PTY_PASSWORDS" -ge 1
    check "a wrong password ends the install with a failure" test "$PTY_RC" -ne 0
    check "and sudo said so" has "incorrect password"
    check "and no git was built into /usr/local" test ! -e /usr/local/bin/git
    check "the wrong password is not in the transcript" not has "$wrong"
    check "the real password is not in the transcript" not has "$pw"
    pty_session "$HOME/pty-right.out" "$pw" "$GSG install"
    show "$(printf '%s' "$OUT" | tr -d '\r' | grep -E 'Upgrade git|password|route:|installed git-secret-guard' | head -n 8 | cut -c1-160)"
    show "sudo asked for the password $PTY_PASSWORDS time(s) during the run (its cache lasts a few minutes)"
    check "the right password ends the install with exit 0" test "$PTY_RC" -eq 0
    check "the consent question was answered on the terminal" test "$PTY_ASKED" -ge 1
    check "git was built into /usr/local and is new enough" ver_ge_254 /usr/local/bin/git
    check "the real password is not in the transcript of the run that used it" not has "$pw"
    check "a commit with a fake key is blocked and a clean one passes" blocked_commit git
}

# ^ invariant the pin bump builds git at the older pin and runs install from a checkout whose tools.lock pins the current one
mode_bump() {
    local cur lock="$CK/tools.lock" docs=/usr/local/share/doc
    printf '== Rocky: a real pin bump of git (%s, then the current pin)\n' "$BUMP_OLD_VERSION"
    cur="$(awk '$1 == "git" && $3 == "source" { print $2 }' "$lock")"
    cp "$lock" "$HOME/tools.lock.current" || { bad "tools.lock cannot be copied"; return 1; }
    check "the current pin is newer than the older one" test "$cur" != "$BUMP_OLD_VERSION"
    awk -v v="$BUMP_OLD_VERSION" -v s="$BUMP_OLD_SHA" -v m="$BUMP_OLD_MAN_SHA" \
        '$1 == "git" && $3 == "source" { print "git " v " source " s; next } $1 == "git-manpages" && $3 == "source" { print "git-manpages " v " source " m; next } { print }' \
        "$HOME/tools.lock.current" >"$lock"
    check "the checkout pins $BUMP_OLD_VERSION for now" grep -q "^git $BUMP_OLD_VERSION source " "$lock"
    # ^ why a first build without the flag, not the current code; it stands for a build made before INSTALL_SYMLINKS=1, whose files are hard links
    cp "$CK/lib/gitup_source.sh" "$HOME/gitup_source.sh.current" || { bad "gitup_source.sh cannot be copied"; return 1; }
    sed -i 's/ INSTALL_SYMLINKS=1//g' "$CK/lib/gitup_source.sh"
    check "the first build is made without INSTALL_SYMLINKS=1" test -z "$(grep -c INSTALL_SYMLINKS=1 "$CK/lib/gitup_source.sh" | grep -v "^0$")"
    run "$GSG" install --upgrade-git </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'route:|download git|installed git-secret-guard' | head -n 4 | cut -c1-140)"
    check "install at the older pin exits 0" rc_is 0
    check "git $BUMP_OLD_VERSION is in /usr/local" test "$(git_ver /usr/local/bin/git)" = "$BUMP_OLD_VERSION"
    check "and its MANIFEST is in a directory named for it" test -f "$docs/git-$BUMP_OLD_VERSION-local/MANIFEST"
    check "that build has hard links: git has more than one name" test "$(stat -c %h /usr/local/bin/git)" -gt 1
    cp "$HOME/gitup_source.sh.current" "$CK/lib/gitup_source.sh" || { bad "gitup_source.sh cannot be restored"; return 1; }
    check "the code is the current one again, with the flag" grep -q 'INSTALL_SYMLINKS=1' "$CK/lib/gitup_source.sh"
    run "$GSG" install --upgrade-git </dev/null
    check "at the same pin the hard-link build is not rebuilt: no plan" not has "plan"
    check "and it still has hard links" test "$(stat -c %h /usr/local/bin/git)" -gt 1
    cp "$HOME/tools.lock.current" "$lock"
    check "the checkout pins $cur again" grep -q "^git $cur source " "$lock"
    run "$GSG" install </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'older than the git this version pins|Rebuild git|--upgrade-git' | head -n 3 | cut -c1-170)"
    check "without the flag and a terminal the rebuild is offered, never done" has "older than the git this version pins ($cur)"
    check "and git is still $BUMP_OLD_VERSION" test "$(git_ver /usr/local/bin/git)" = "$BUMP_OLD_VERSION"
    run "$GSG" install --upgrade-git </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'rebuild plan|route:|previous build|installed git-secret-guard' | head -n 5 | cut -c1-170)"
    check "the rebuild at the current pin exits 0" rc_is 0
    check "git $cur is in /usr/local" test "$(git_ver /usr/local/bin/git)" = "$cur"
    check "its MANIFEST is there" test -f "$docs/git-$cur-local/MANIFEST"
    check "the directory of the older build is gone" test ! -e "$docs/git-$BUMP_OLD_VERSION-local"
    check "the rebuild turned the hard links into symlinks: git has one name" test "$(stat -c %h /usr/local/bin/git)" = 1
    check "and the libexec entry git-merge is a symlink" test -L /usr/local/libexec/git-core/git-merge
    check "no libexec entry is a second name of git" test -z "$(find /usr/local/libexec/git-core -maxdepth 1 -type f -samefile /usr/local/bin/git)"
    check "it is still first on PATH" test "$(command -v git)" = /usr/local/bin/git
    check "the RPM git is untouched" rpm_clean
    check "a commit with a fake key is blocked and a clean one passes" blocked_commit git
    run "$GSG" install --upgrade-git </dev/null
    check "a rerun exits 0" rc_is 0
    check "and prints no plan" not has "upgrade plan"
}

# ^ invariant Fedora with the Fedora 41 git-core 2.47.0 installed; install --upgrade-git takes the package route and the package really changes
mode_old() {
    printf '== Fedora: an old RPM git (git-core 2.47.0), install --upgrade-git (package route)\n'
    PKG_BEFORE="$(rpm -q git-core)"
    show "$(git --version) from $(command -v git); $PKG_BEFORE"
    check "the machine starts with an RPM git older than 2.54" not ver_ge_254 /usr/bin/git
    check "and it is the git on PATH" test "$(command -v git)" = /usr/bin/git
    run "$GSG" install </dev/null
    check "install without the flag and without a terminal refuses" rc_is 1
    check "and names --upgrade-git" has "--upgrade-git"
    check "and says nothing was changed" has "nothing was changed"
    check "git-core is the same package" test "$(rpm -q git-core)" = "$PKG_BEFORE"
    run "$GSG" install --upgrade-git </dev/null
    show "$(printf '%s' "$OUT" | grep -E 'route:|now; continuing|installed git-secret-guard|neither' | head -n 6 | cut -c1-160)"
    show "exit $RC; the last lines of the output:" "$(printf '%s' "$OUT" | tail -n 14 | cut -c1-200)"
    check "install --upgrade-git ends with exit 0" rc_is 0
    check "the plan named the package route" has "route: package"
    check "no source build ran" not has "building git"
    show "$(git --version) from $(command -v git); $(rpm -q git-core)"
    check "git-core is a different package now" test "$(rpm -q git-core)" != "$PKG_BEFORE"
    check "git is new enough" ver_ge_254 "$(command -v git)"
    check "git comes from the package, in /usr/bin" test "$(command -v git)" = /usr/bin/git
    check "nothing was built into /usr/local" test ! -e /usr/local/bin/git
    check "a commit with a fake key is blocked and a clean one passes" blocked_commit git
    run "$GSG" install --upgrade-git </dev/null
    check "a rerun exits 0" rc_is 0
    check "a rerun prints no plan" not has "upgrade plan"
}

# ^ invariant stage 1 of the offline restore upgrades and takes over on Rocky, and keeps what stage 2 compares against in a file under HOME
mode_takeover() {
    rocky_upgrade
    rocky_takeover
    run "$GSG" status
    check "status reports the active takeover" has "system git takeover: active"
    if ! declare -p SUMS_BEFORE PKG_BEFORE LINKS_BEFORE >"$STATE_FILE"; then bad "the state for stage 2 could not be saved"; fi
}

# ^ invariant stage 2 runs with no network; restore-system-git and uninstall must work from the saved originals alone
mode_offline() {
    local ifaces
    printf '== Rocky: restore-system-git and uninstall with the network off\n'
    # shellcheck source=/dev/null
    if ! source "$STATE_FILE"; then
        bad "no state of stage 1 in $STATE_FILE"
        return 1
    fi
    ifaces="$(awk -F: 'NR > 2 { gsub(/ /, "", $1); print $1 }' /proc/net/dev | tr '\n' ' ')"
    show "interfaces: $ifaces"
    check "the only network interface is the loopback" test "$ifaces" = "lo "
    check "a download from kernel.org fails" not curl -sS --max-time 15 -o /dev/null https://www.kernel.org/
    check "a name cannot be resolved" not getent hosts www.kernel.org
    run "$GSG" status
    check "stage 1 left the takeover active" has "system git takeover: active"
    run "$GSG" restore-system-git </dev/null
    show "$OUT"
    check "restore-system-git exits 0 with no network" rc_is 0
    check "the six RPM files are back, byte for byte" test "$(usrbin_sums)" = "$SUMS_BEFORE"
    check "and as the same links" test "$(usrbin_links)" = "$LINKS_BEFORE"
    check "rpm -V git-core is clean again" rpm_clean
    check "dnf.conf is as it was" cmp -s "$HOME/dnf.conf.before" /etc/dnf/dnf.conf
    check "the backup directory is gone" test ! -e /var/lib/git-secret-guard/system-git
    run "$GSG" restore-system-git </dev/null
    check "a second restore says nothing to restore" has "nothing to restore"
    run "$GSG" uninstall </dev/null
    check "uninstall exits 0 with no network" rc_is 0
}

main_more() {
    local distro="$DISTRO"
    case "$distro:$MODE" in
        rocky:root) mode_root ;;
        rocky:password) mode_password ;;
        rocky:bump) mode_bump ;;
        rocky:takeover) mode_takeover ;;
        rocky:offline) mode_offline ;;
        fedora:old) mode_old ;;
        *)
            printf 'usage: rpm-more-e2e.sh rocky root|password|bump|takeover|offline | fedora old\n' >&2
            exit 2
            ;;
    esac
    e2e_summary
}

main_more
