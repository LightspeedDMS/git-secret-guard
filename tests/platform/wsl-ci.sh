#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2012,SC2015
set -u
# ^ external runs inside a WSL distribution on a disposable GitHub Windows runner (.github/workflows/wsl.yml) and refuses to run anywhere else
# ^ security the fake credential is built at runtime from fragments and never printed; every output is checked for its absence before any of it is shown
# ^ coupled phases are facts probe upgrade mntc installed-cli tests, one per workflow step; WS is the checkout, MAIN a checkout of main, LOGS the log directory

PHASE="${1:-}"
WS="${WS:-}"
MAIN="${MAIN:-}"
LOGS="${LOGS:-$HOME/wsl-logs}"
LINUX_CK="$HOME/gsg-linux"
MNTC="/mnt/c/gsg-ci"
RESULTS="$LOGS/results.txt"
fails=0
RC=0
OUT=""

# ^ security decided before anything is written; WSLENV carries GITHUB_ACTIONS from the Windows side, and a developer machine never has it set to true
if [ "${GITHUB_ACTIONS:-}" != true ]; then
    printf 'wsl-ci.sh: refused: this script runs only in GitHub Actions (GITHUB_ACTIONS=true); it installs software and renames directories, see .github/workflows/wsl.yml\n' >&2
    exit 2
fi
mkdir -p -- "$LOGS" || exit 2
ok() { printf 'PASS    %s\n' "$1" | tee -a "$RESULTS"; }
bad() {
    printf 'FAIL    %s\n' "$1" | tee -a "$RESULTS"
    fails=$((fails + 1))
}
info() { printf 'INFO    %s\n' "$1" | tee -a "$RESULTS"; }
check() { if "${@:2}"; then ok "$1"; else bad "$1"; fi; }
show() { printf '        | %s\n' "$@"; }
has() { [[ $OUT == *"$1"* ]]; }
rc_is() { [ "$RC" -eq "$1" ]; }
# ^ invariant run LABEL CMD... keeps stdout and stderr in LOGS/LABEL.log and in OUT; output holding the fake key is never kept
run() {
    local label="$1"
    shift
    "$@" >"$LOGS/$label.raw" 2>&1 </dev/null
    RC=$?
    OUT="$(<"$LOGS/$label.raw")"
    if [[ $OUT == *"$(fake_key)"* ]]; then
        rm -f -- "$LOGS/$label.raw"
        OUT=""
        bad "$label: the output held the fake key, log removed"
        return 0
    fi
    mv -- "$LOGS/$label.raw" "$LOGS/$label.log"
}
fake_key() { printf '%s%s' "AKI""A" "Q7XK2MWB4HZ5NR3T"; }
ver_ge_254() {
    local v
    v="$(git --version | sed 's/^git version //')" || return 1
    [[ $v =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    [ "${BASH_REMATCH[1]}" -gt 2 ] || { [ "${BASH_REMATCH[1]}" -eq 2 ] && [ "${BASH_REMATCH[2]}" -ge 54 ]; }
}
need_ws() {
    if [ ! -d "${WS:-}" ]; then
        printf 'wsl-ci.sh: WS must name the checkout\n' >&2
        exit 2
    fi
}

# ^ invariant commit_probe DIR CONTENT LABEL commits CONTENT in a fresh repository and sets RC and OUT; rc 1 = the repository could not be made
commit_probe() {
    local d="$1" content="$2" label="$3"
    rm -rf -- "${d:?}" && mkdir -p -- "$d" || return 1
    git init -q "$d" && git -C "$d" config user.name gsg && git -C "$d" config user.email gsg@example.invalid || return 1
    printf '%s\n' "$content" >"$d/a.txt" && git -C "$d" add a.txt || return 1
    run "$label" git -C "$d" commit -q -m probe
}

# ^ invariant a commit with the fake key is blocked by the hook's own finding line and a clean one passes; $1 = the directory for the repository, $2 = a label
blocked_and_clean() {
    local d="$1" label="$2" t0 t1
    t0=$SECONDS
    commit_probe "$d" "aws_access_key_id = $(fake_key)" "$label-leak" || { bad "$label: could not prepare the repository"; return 0; }
    t1=$SECONDS
    check "$label: the commit with a fake key is blocked (rc $RC)" test "$RC" -ne 0
    check "$label: the finding line is printed" has "potential secret(s) in lines this commit adds"
    info "$label: blocked commit took $((t1 - t0)) s"
    commit_probe "$d" "clean content" "$label-clean" || { bad "$label: could not prepare the clean repository"; return 0; }
    check "$label: a clean commit passes" rc_is 0
}

phase_facts() {
    {
        printf 'kernel: %s\n' "$(uname -r)"
        printf 'proc version: %s\n' "$(cat /proc/version)"
        printf 'os-release: %s\n' "$(grep -E '^(ID|VERSION_ID)=' /etc/os-release | tr '\n' ' ')"
        printf 'git: %s at %s\n' "$(git --version)" "$(command -v git)"
        printf 'WSLInterop: %s\n' "$(ls /proc/sys/fs/binfmt_misc 2>&1 | tr '\n' ' ')"
        printf 'WSL_DISTRO_NAME=[%s] WSL_INTEROP=[%s]\n' "${WSL_DISTRO_NAME:-}" "${WSL_INTEROP:-}"
        printf 'pid 1: %s; /run/systemd/system: %s\n' "$(ps -p 1 -o comm= 2>&1)" "$([ -d /run/systemd/system ] && echo present || echo absent)"
        printf 'umask: %s; user: %s\n' "$(umask)" "$(id -un)"
        printf 'mounts: %s\n' "$(grep -E ' /mnt/[a-z] ' /proc/mounts | tr '\n' ';')"
        printf 'tools: sudo=%s jq=%s setsid=%s timeout=%s add-apt-repository=%s\n' "$(command -v sudo)" "$(command -v jq)" "$(command -v setsid)" "$(command -v timeout)" "$(command -v add-apt-repository)"
        printf 'windows git on PATH: %s\n' "$(type -P git.exe || echo none)"
    } 2>&1 | tee "$LOGS/facts.log"
    # ^ invariant what the product's own detection says on this machine; a wrong answer fails the job
    check "wsl_is says WSL" bash -c 'source "$1/lib/wsl.sh" && wsl_is' _ "$WS"
    info "wsl_version says $(bash -c 'source "$1/lib/wsl.sh" && wsl_version && echo "$REPLY"' _ "$WS")"
}

# ^ hazard HYPOTHESIS not shown yet; the installed-CLI install fails on WSL 1 as the running script pins its directory, and this probe renames one
phase_probe() {
    local base
    need_ws
    base="$(mktemp -d "$HOME/rename-probe.XXXXXX")" || exit 2
    case "$base" in /?*) ;; *) exit 2 ;; esac
    mkdir -p -- "$base/share/bin" || exit 2
    printf '#!/usr/bin/env bash\nmv "$1/share" "$1/moved"; echo "HYPOTHESIS probe, rename of the directory holding this running script: rc=$?"\n[ -d "$1/moved" ] && mv "$1/moved" "$1/share"\nmv "$1/share/bin" "$1/share/bin2"; echo "HYPOTHESIS probe, rename of its parent directory: rc=$?"\n[ -d "$1/share/bin2" ] && mv "$1/share/bin2" "$1/share/bin"\nexit 0\n' >"$base/share/bin/run"
    chmod 755 -- "$base/share/bin/run"
    run probe "$base/share/bin/run" "$base"
    show "$OUT"
    info "HYPOTHESIS probe (rc 0 for both renames counts against the hypothesis, a failure supports it): $(printf '%s' "$OUT" | tr '\n' ' ')"
    rm -rf -- "${base:?}"
}

phase_upgrade() {
    need_ws
    rm -rf -- "$LINUX_CK" && cp -a -- "$WS" "$LINUX_CK" || exit 2
    check "the machine starts with a git older than 2.54" bash -c '! git --version | grep -Eq "git version (2\.(5[4-9]|[6-9][0-9])|[3-9])"'
    run upgrade-refuse "$LINUX_CK/bin/git-secret-guard" install
    check "install without --upgrade-git refuses on the old git" test "$RC" -ne 0
    run upgrade "$LINUX_CK/bin/git-secret-guard" install --upgrade-git
    show "$(printf '%s' "$OUT" | grep -E 'upgrade plan|note:|route:|as root:' | cut -c1-200 | head -n 14)"
    check "install --upgrade-git exits 0 (rc $RC)" rc_is 0
    check "the plan says it is a WSL plan" has "git upgrade plan for this wsl system"
    check "the plan says it applies to this distribution only" has "this upgrades git inside this WSL distribution only"
    check "git is 2.54 or newer afterwards ($(git --version))" ver_ge_254
    run status "$HOME/.local/bin/git-secret-guard" status
    check "status exits 0" rc_is 0
    blocked_and_clean "$HOME/repo-linux" linux
    run rerun "$LINUX_CK/bin/git-secret-guard" install --upgrade-git
    check "a rerun exits 0" rc_is 0
    check "a rerun offers no upgrade plan" bash -c '! grep -q "upgrade plan" "$1"' _ "$LOGS/rerun.log"
    check "a rerun runs no privileged command" bash -c '! grep -q "as root:" "$1"' _ "$LOGS/rerun.log"
    if type -P git.exe >/dev/null; then
        check "a reachable git.exe is explained as a separate setup" bash -c 'grep -q "two separate git setups" "$1"' _ "$LOGS/upgrade.log"
    else
        info "no git.exe on PATH here, the two-setups notice was not exercised"
    fi
    run timer "$LINUX_CK/bin/git-secret-guard" install --with-timer
    info "install --with-timer: rc $RC; $(printf '%s' "$OUT" | head -n 3 | tr '\n' ' ' | cut -c1-300)"
    if [ -d /run/systemd/system ]; then
        check "systemd runs here, so --with-timer is not refused (rc $RC)" rc_is 0
    else
        check "--with-timer is refused without systemd" test "$RC" -ne 0
        # ^ invariant same rule as the product (wsl_version) => a capital M in the kernel text is WSL 1, anything else WSL 2
        if ! grep -q 'Microsoft' /proc/sys/kernel/osrelease; then
            check "WSL 2: the wsl.conf fix is printed" has "systemd=true"
        else
            check "WSL 1: it says the timer is not available" has "not available on WSL 1"
            check "WSL 1: no wsl.conf fix is printed" bash -c '! grep -q "wsl.conf" "$1"' _ "$LOGS/timer.log"
        fi
    fi
}

# ^ invariant a repository and an install checkout under /mnt/c; WSL 1 mounts the drive without metadata and files show mode 777
phase_mntc() {
    need_ws
    if [ ! -d /mnt/c ]; then bad "/mnt/c is not mounted"; return 0; fi
    mkdir -p -- "$MNTC" || { bad "cannot create $MNTC"; return 0; }
    info "mount of /mnt/c: $(grep ' /mnt/c ' /proc/mounts | cut -c1-200)"
    blocked_and_clean "$MNTC/repo" mntc-repo
    rm -rf -- "${MNTC:?}/checkout" && cp -a -- "$WS" "$MNTC/checkout" || { bad "cannot copy the checkout to $MNTC"; return 0; }
    info "a file in the /mnt/c checkout shows mode $(stat -c %a "$MNTC/checkout/bin/git-secret-guard")"
    run mntc-install "$MNTC/checkout/bin/git-secret-guard" install
    check "install from a checkout under /mnt/c exits 0 (rc $RC)" rc_is 0
    check "nothing the hook runs is group or other writable after it" bash -c '[ -z "$(find "$HOME/.local/share/git-secret-guard" -perm /022 ! -type l | head -n 1)" ]'
    blocked_and_clean "$HOME/repo-after-mntc" mntc-install
}

# ^ hazard HYPOTHESIS see phase_probe; main has no WSL pin, its installed CLI is the unfixed code, and this phase records whether its install fails
phase_installed_cli() {
    need_ws
    local cli="$HOME/.local/bin/git-secret-guard"
    if [ -n "$MAIN" ] && [ -d "$MAIN" ]; then
        run main-install "$MAIN/bin/git-secret-guard" install
        info "main: install from its checkout, rc $RC"
        run main-installed-cli "$cli" install
        info "main: the installed CLI install, rc $RC; $(printf '%s' "$OUT" | grep -E 'mv:|cannot move|Permission denied' | head -n 2 | cut -c1-240)"
    else
        bad "no checkout of main was given, so the unfixed code was not run and the hypothesis cannot be judged"
    fi
    run branch-install "$WS/bin/git-secret-guard" install
    check "this branch: install from the checkout exits 0 (rc $RC)" rc_is 0
    run branch-installed-cli "$cli" install
    check "this branch: the installed CLI install exits 0 (rc $RC)" rc_is 0
    check "this branch: no mv error" bash -c '! grep -q "cannot move" "$1"' _ "$LOGS/branch-installed-cli.log"
    run branch-doctor "$cli" doctor --roots "$HOME/repo-linux"
    info "doctor on the Linux repository: rc $RC"
}

phase_tests() {
    local f rc
    need_ws
    export GSG_TEST_JOBS=1
    GSG_TEST_GIT="$(command -v git)"
    export GSG_TEST_GIT
    cd -- "$LINUX_CK" || exit 2
    for f in test_wsl test_gitup test_gitup_contract test_gitup_apt test_gitup_apt_ppa test_gitup_apt_state test_prerequisites test_install test_timer; do
        tests/run.sh "tests/$f.sh" >"$LOGS/suite-$f.log" 2>&1 </dev/null
        rc=$?
        info "tests/$f.sh: rc $rc; $(grep '^SUMMARY' "$LOGS/suite-$f.log" | tail -n 1)"
        if [ "$rc" -ne 0 ]; then
            bad "tests/$f.sh failed"
            grep -E '^(FAIL|  )' "$LOGS/suite-$f.log" | cut -c1-240 | head -n 20
        fi
    done
}

case "$PHASE" in
    facts) phase_facts ;;
    probe) phase_probe ;;
    upgrade) phase_upgrade ;;
    mntc) phase_mntc ;;
    installed-cli) phase_installed_cli ;;
    tests) phase_tests ;;
    *)
        printf 'usage: tests/platform/wsl-ci.sh facts|probe|upgrade|mntc|installed-cli|tests\n' >&2
        exit 2
        ;;
esac
[ "$fails" -eq 0 ]
