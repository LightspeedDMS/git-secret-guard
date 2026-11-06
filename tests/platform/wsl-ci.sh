#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2012,SC2015
set -u
# ^ external runs inside a WSL distribution on a disposable GitHub Windows runner (.github/workflows/wsl.yml) and refuses to run anywhere else
# ^ security the fake credential is built at runtime from fragments and never printed; every output is checked for its absence before any of it is shown
# ^ coupled phases are prepare facts probe upgrade mount-for-user mntc installed-cli tests, one per step; WS, MAIN, LOGS and CONSENT come from the workflow

# ^ external wsl.exe -e bash gives SHELL=bash, a bare name, and script -c failed on it (run 42280191940); a login shell has SHELL=/bin/bash
export SHELL=/bin/bash
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
: >>"$RESULTS" || exit 2
if [ "$(id -u)" -eq 0 ]; then chmod 666 "$RESULTS" || exit 2; fi
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
# ^ invariant run LABEL CMD... keeps stdout and stderr in LOGS/LABEL.log and in OUT, stdin is RUN_STDIN or /dev/null; output holding the fake key is never kept
run() {
    local label="$1"
    shift
    "$@" >"$LOGS/$label.raw" 2>&1 <"${RUN_STDIN:-/dev/null}"
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

# ^ invariant commit_probe DIR CONTENT LABEL commits CONTENT in a fresh repository, sets RC and OUT; rc 1 = no repository, the error is in LOGS/LABEL-prep.log
commit_probe() {
    local d="$1" content="$2" label="$3"
    case "$d" in /?*/?*) ;; *) return 1 ;; esac
    rm -rf -- "${d:?}" && mkdir -p -- "$d" || return 1
    run "$label-prep" bash -c 'git init -q "$1" && git -C "$1" config user.name gsg && git -C "$1" config user.email gsg@example.invalid && printf "%s\n" "$2" >"$1/a.txt" && git -C "$1" add a.txt' _ "$d" "$content"
    [ "$RC" -eq 0 ] || return 1
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

# ^ external the vendor WSL images of Rocky and Fedora hold no git, jq, ps or user to test with; this root phase adds them from the repositories
# ^ invariant prepare runs as root once, after the distribution exists; it adds git as the repository ships it and a user with sudo, as a developer has
phase_prepare() {
    if [ "$(id -u)" -ne 0 ]; then bad "prepare must run as root"; return 0; fi
    if command -v dnf >/dev/null 2>&1; then
        run prepare-update dnf upgrade -y --refresh
        check "dnf upgrade, as a developer distribution has had (rc $RC)" rc_is 0
        run prepare-dnf dnf install -y git jq procps-ng shadow-utils sudo curl tar xz util-linux findutils
        check "dnf installed the tools (rc $RC)" rc_is 0
    fi
    info "stock git: $(git --version); $(grep -E '^(ID|VERSION_ID)=' /etc/os-release | tr '\n' ' ')"
    id gsg >/dev/null 2>&1 || useradd -m -s /bin/bash gsg
    printf 'gsg ALL=(ALL) NOPASSWD:ALL\n' >/etc/sudoers.d/gsg && chmod 440 /etc/sudoers.d/gsg
    check "the test user exists with sudo" bash -c 'id gsg >/dev/null && sudo -n -u gsg true'
    chmod 777 "$LOGS"
    chmod -R a+rX "$WS" "$MAIN" || true
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
    # ^ external script -c failed on WSL 1 with No such file or directory for its command (run 42278536933); the pty routes are probed here
    {
        printf 'script version: %s\n' "$(script --version 2>&1 | head -n 1)"
        printf 'SHELL=[%s] /bin/sh -> %s\n' "${SHELL:-}" "$(readlink -f /bin/sh)"
        printf 'script -qefc: [%s]\n' "$(timeout 20 script -qefc 'echo via-script' /dev/null 2>&1 </dev/null | tr '\r\n' '  ')"
        printf 'SHELL=/bin/bash script -qefc: [%s]\n' "$(SHELL=/bin/bash timeout 20 script -qefc 'echo via-script-bash' /dev/null 2>&1 </dev/null | tr '\r\n' '  ')"
        printf 'script -qefc with an absolute path: [%s]\n' "$(timeout 20 script -qefc '/bin/echo via-script-abs' /dev/null 2>&1 </dev/null | tr '\r\n' '  ')"
        printf 'python3 pty: [%s]\n' "$(timeout 20 python3 -c 'import pty,sys; sys.exit(pty.spawn(["/bin/echo","via-python-pty"]))' 2>&1 </dev/null | tr '\r\n' '  ')"
    } 2>&1 | tee "$LOGS/pty-probe.log"
    # ^ invariant what the product's own detection says on this machine; a wrong answer fails the job
    check "wsl_is says WSL" bash -c 'source "$1/lib/wsl.sh" && wsl_is' _ "$WS"
    info "wsl_version says $(bash -c 'source "$1/lib/wsl.sh" && wsl_version && echo "$REPLY"' _ "$WS")"
}

# ^ external renaming the directory of a running script fails on WSL 1 (4.4.0-20348-Microsoft, rc 1) and works on WSL 2 (6.18.54.1-microsoft-standard-WSL2)
phase_probe() {
    local base
    need_ws
    base="$(mktemp -d "$HOME/rename-probe.XXXXXX")" || exit 2
    case "$base" in /?*) ;; *) exit 2 ;; esac
    mkdir -p -- "$base/share/bin" || exit 2
    printf '#!/usr/bin/env bash\nmv "$1/share" "$1/moved"; echo "probe, rename of the directory holding this running script: rc=$?"\n[ -d "$1/moved" ] && mv "$1/moved" "$1/share"\nmv "$1/share/bin" "$1/share/bin2"; echo "probe, rename of its parent directory: rc=$?"\n[ -d "$1/share/bin2" ] && mv "$1/share/bin2" "$1/share/bin"\nexit 0\n' >"$base/share/bin/run"
    chmod 755 -- "$base/share/bin/run"
    run probe "$base/share/bin/run" "$base"
    show "$OUT"
    info "rename probe (measured: rc 1 on WSL 1 build 20348, rc 0 on WSL 2): $(printf '%s' "$OUT" | tr '\n' ' ')"
    rm -rf -- "${base:?}"
}

# ^ invariant typed_install ANSWERS LABEL CMD... runs CMD on a pty (script) and types ANSWERS; backslash n splits answers; RC is the command rc
# ^ why a fifo held open by a writer, not a pipe from printf; EOF on the stdin of script ends the session before a long install is done
typed_install() {
    local answers="$1" label="$2" dir writer
    shift 2
    dir="$(mktemp -d "$HOME/typed.XXXXXX")" || return 1
    case "$dir" in /?*/?*) ;; *) return 1 ;; esac
    mkfifo "$dir/in" || return 1
    { printf '%b\n' "$answers"; exec sleep 3000; } >"$dir/in" &
    writer=$!
    RUN_STDIN="$dir/in" run "$label" timeout 3000 script -qefc "$*" /dev/null
    kill "$writer" 2>/dev/null
    wait "$writer" 2>/dev/null
    rm -rf -- "${dir:?}"
}

# ^ invariant true when nothing of an upgrade is on the machine, meaning no git under /usr/local, no git-core PPA file and no install state
no_upgrade_artifacts() {
    [ ! -e /usr/local/bin/git ] && ! compgen -G '/etc/apt/sources.list.d/git-core*' >/dev/null && [ ! -e "$HOME/.local/share/git-secret-guard" ]
}

phase_upgrade() {
    local stock_old=1 before
    need_ws
    rm -rf -- "$LINUX_CK" && cp -a -- "$WS" "$LINUX_CK" || exit 2
    if ! command -v awk >/dev/null 2>&1; then
        run awk-refuse "$LINUX_CK/bin/git-secret-guard" install --upgrade-git
        check "no awk on the image: install refuses (rc $RC)" test "$RC" -ne 0
        check "and names awk with its package" has "awk is required but was not found on PATH"
        run awk-install sudo dnf install -y gawk
        check "gawk installed (rc $RC)" rc_is 0
    fi
    if ver_ge_254; then stock_old=0; info "stock git is already $(git --version): there is nothing to upgrade, the flow below checks that nothing is offered"; fi
    if [ "$stock_old" -eq 1 ]; then
        before="$(git --version)"
        typed_install n typed-no "$LINUX_CK/bin/git-secret-guard" install
        check "typed No: the prompt is shown" has "Upgrade git now with the plan above? [y/N]"
        check "typed No: install refuses (rc $RC)" test "$RC" -ne 0
        check "typed No: git is unchanged ($before)" test "$(git --version)" = "$before"
        check "typed No: nothing of an upgrade or an install is on the machine" no_upgrade_artifacts
        run upgrade-refuse "$LINUX_CK/bin/git-secret-guard" install
        check "install without a terminal and without --upgrade-git refuses on the old git" test "$RC" -ne 0
        if [ "${CONSENT:-flag}" = typed ]; then
            # ^ see the second answer; an RPM distribution asks again about the takeover of /usr/bin/git
            typed_install 'y\nn' upgrade "$LINUX_CK/bin/git-secret-guard" install
            check "typed yes: the prompt is shown" has "Upgrade git now with the plan above? [y/N]"
            check "typed yes: install exits 0 (rc $RC)" rc_is 0
        else
            run upgrade "$LINUX_CK/bin/git-secret-guard" install --upgrade-git
            check "install --upgrade-git exits 0 (rc $RC)" rc_is 0
        fi
    else
        run upgrade "$LINUX_CK/bin/git-secret-guard" install --upgrade-git
        check "stock git is new enough: install exits 0 (rc $RC)" rc_is 0
        check "and offers no upgrade" bash -c '! grep -q "upgrade plan" "$1"' _ "$LOGS/upgrade.log"
    fi
    show "$(printf '%s' "$OUT" | grep -E 'upgrade plan|note:|route:|as root:' | cut -c1-200 | head -n 14)"
    if [ "$stock_old" -eq 1 ]; then
        check "the plan says it is a WSL plan" has "git upgrade plan for this wsl system"
        check "the plan says it applies to this distribution only" has "this upgrades git inside this WSL distribution only"
    fi
    check "git is 2.54 or newer afterwards ($(git --version))" ver_ge_254
    run status "$HOME/.local/bin/git-secret-guard" status
    check "status exits 0" rc_is 0
    blocked_and_clean "$HOME/repo-linux" linux
    run rerun "$LINUX_CK/bin/git-secret-guard" install --upgrade-git
    check "a rerun exits 0" rc_is 0
    check "a rerun offers no upgrade plan" bash -c '! grep -q "upgrade plan" "$1"' _ "$LOGS/rerun.log"
    check "a rerun runs no privileged command except a system git takeover plan it only prints" bash -c '! grep -q "as root:" "$1" || grep -q "system git takeover plan" "$1"' _ "$LOGS/rerun.log"
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

# ^ external the runner mounts the drive for root (WSL 1 drvfs uid=0, WSL 2 9p uid=0); a developer mount carries their uid (uid=1000 measured on a distribution)
# ^ invariant mount-for-user runs as root before mntc and remounts /mnt/c for the test user; mntc runs as the user and fails if the mount is not theirs
phase_mount_for_user() {
    local extra="${1:-}"
    local user=gsg u g
    if [ "$(id -u)" -ne 0 ]; then bad "mount-for-user must run as root"; return 0; fi
    if ! id "$user" >/dev/null 2>&1; then bad "the user $user does not exist"; return 0; fi
    u="$(id -u "$user")"
    g="$(id -g "$user")"
    case "$u$g" in '' | *[!0-9]*) bad "no numeric uid and gid for $user"; return 0 ;; esac
    info "mount of /mnt/c before: $(grep ' /mnt/c ' /proc/mounts | cut -c1-200)"
    run mount-umount umount /mnt/c
    if [ "$RC" -ne 0 ]; then
        info "umount /mnt/c failed (rc $RC), trying a lazy umount"
        run mount-umount-lazy umount -l /mnt/c
    fi
    run mount-mount mount -t drvfs 'C:' /mnt/c -o "uid=$u,gid=$g,noatime${extra:+,$extra}"
    if [ "$RC" -ne 0 ]; then
        info "mount -t drvfs failed (rc $RC): $(printf '%s' "$OUT" | head -n 2 | tr '\n' ' ' | cut -c1-200)"
        run mount-remount mount -o "remount,uid=$u,gid=$g${extra:+,$extra}" /mnt/c
    fi
    info "mount of /mnt/c after: $(grep ' /mnt/c ' /proc/mounts | cut -c1-200)"
    check "/mnt/c is mounted for $user (uid $u)" bash -c 'grep -Eq " /mnt/c .*uid=$1[,;]" /proc/mounts' _ "$u"
    if [ -n "$extra" ]; then check "the mount carries $extra" bash -c 'grep " /mnt/c " /proc/mounts | grep -q "$1"' _ "$extra"; fi
}

# ^ invariant a repository and an install checkout under /mnt/c; WSL 1 mounts the drive without metadata and files show mode 777
phase_mntc() {
    local sfx="${1:-}" dir="$MNTC${1:+-$1}" lab="mntc${1:+-$1}" f
    need_ws
    if [ ! -d /mnt/c ]; then bad "/mnt/c is not mounted"; return 0; fi
    case "$dir" in /mnt/c/?*) ;; *) bad "$dir is not a directory below /mnt/c"; return 0 ;; esac
    mkdir -p -- "$dir" || { bad "cannot create $dir"; return 0; }
    info "mount of /mnt/c: $(grep ' /mnt/c ' /proc/mounts | cut -c1-200)"
    check "the drive is mounted for this user (uid $(id -u)), as on a developer's machine" bash -c 'grep -Eq " /mnt/c .*uid=$1[,;]" /proc/mounts' _ "$(id -u)"
    blocked_and_clean "$dir/repo" "$lab-repo"
    run "$lab-copy" bash -c 'rm -rf -- "$1/checkout" && cp -a -- "$2" "$1/checkout"' _ "$dir" "$WS"
    if [ "$RC" -ne 0 ]; then bad "cannot copy the checkout to $dir (rc $RC, see $lab-copy.log)"; return 0; fi
    : >"$dir/new-file" && chmod 644 "$dir/new-file" && info "$lab: a new file made here shows mode $(stat -c %a "$dir/new-file") after chmod 644, and a new directory $(mkdir -p "$dir/new-dir" && stat -c %a "$dir/new-dir")"
    for f in bin/git-secret-guard README.md lib/common.sh; do info "$lab: a file in the /mnt/c checkout, $f, shows mode $(stat -c %a "$dir/checkout/$f")"; done
    if [ "$sfx" = metadata ]; then
        chmod 640 "$dir/checkout/README.md" && info "$lab: README.md after chmod 640 shows mode $(stat -c %a "$dir/checkout/README.md")"
        chmod 755 "$dir/checkout/README.md"
    fi
    run "$lab-install" "$dir/checkout/bin/git-secret-guard" install
    check "install from a checkout under /mnt/c exits 0 (rc $RC)" rc_is 0
    check "nothing the hook runs is group or other writable after it" bash -c '[ -z "$(find "$HOME/.local/share/git-secret-guard" -perm /022 ! -type l | head -n 1)" ]'
    blocked_and_clean "$HOME/repo-after-$lab" "$lab-install"
}

# ^ external main has no WSL pin and its installed CLI is the unfixed code; its install fails on WSL 1 with mv Permission denied and passes on WSL 2
phase_installed_cli() {
    need_ws
    local cli="$HOME/.local/bin/git-secret-guard"
    if [ -n "$MAIN" ] && [ -d "$MAIN" ]; then
        run main-install "$MAIN/bin/git-secret-guard" install
        info "main: install from its checkout, rc $RC"
        run main-installed-cli "$cli" install
        info "main: the installed CLI install, rc $RC; $(printf '%s' "$OUT" | grep -E 'mv:|cannot move|Permission denied' | head -n 2 | cut -c1-240)"
    else
        bad "no checkout of main was given, so the unfixed code was not run"
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
    local f rc files="test_wsl test_gitup test_gitup_contract test_gitup_apt test_gitup_apt_ppa test_gitup_apt_state test_prerequisites test_install test_timer"
    need_ws
    export GSG_TEST_JOBS=1
    GSG_TEST_GIT="$(command -v git)"
    export GSG_TEST_GIT
    cd -- "$LINUX_CK" || exit 2
    if grep -Eq "^ID(_LIKE)?=.*(rhel|fedora|rocky)" /etc/os-release; then files="test_wsl test_gitup test_gitup_contract test_gitup_rpm test_prerequisites test_install test_timer"; fi
    for f in $files; do
        tests/run.sh "tests/$f.sh" >"$LOGS/suite-$f.log" 2>&1 </dev/null
        rc=$?
        info "tests/$f.sh: rc $rc; $(grep '^SUMMARY' "$LOGS/suite-$f.log" | tail -n 1)"
        if [ "$rc" -ne 0 ]; then
            bad "tests/$f.sh failed (detail: suite-$f-detail.log)"
            GSG_TEST_DETAIL=4000 tests/run.sh "tests/$f.sh" >"$LOGS/suite-$f-detail.log" 2>&1 </dev/null || true
            grep -E '^(FAIL|  )' "$LOGS/suite-$f.log" | cut -c1-240 | head -n 20
        fi
    done
}

case "$PHASE" in
    facts) phase_facts ;;
    probe) phase_probe ;;
    upgrade) phase_upgrade ;;
    prepare) phase_prepare ;;
    mount-for-user) phase_mount_for_user "${2:-}" ;;
    mntc) phase_mntc "${2:-}" ;;
    installed-cli) phase_installed_cli ;;
    tests) phase_tests ;;
    *)
        printf 'usage: tests/platform/wsl-ci.sh prepare|facts|probe|upgrade|mount-for-user [metadata]|mntc [metadata]|installed-cli|tests\n' >&2
        exit 2
        ;;
esac
[ "$fails" -eq 0 ]
