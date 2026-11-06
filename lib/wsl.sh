# shellcheck shell=bash disable=SC2034
# ^ coupled install-time only; the CLI loads it before gitup.sh and the hook never does (test:test_the_hook_never_loads_the_install_time_libraries)
# ^ coupled behaviour is in docs/platforms.md#wsl-windows-subsystem-for-linux; tests are tests/test_wsl.sh

# ^ external WSL 1 reports 4.4.0-17763-Microsoft (capital M); WSL 2 reports 5.15.x-microsoft-standard-WSL2 or 4.19.x-microsoft-standard (lower case)
# ^ external a Linux container on a WSL 2 host shows the same kernel text and counts as WSL; it only gains the WSL notes and the timer check
# ^ invariant GSG_WSL_OSRELEASE, GSG_WSL_INTEROP and GSG_WSL_SYSTEMD_DIR move the kernel files for tests only; the harness sets them to a plain kernel
WSL_OSRELEASE_FILE="${GSG_WSL_OSRELEASE:-/proc/sys/kernel/osrelease}"
WSL_INTEROP_FILE="${GSG_WSL_INTEROP:-/proc/sys/fs/binfmt_misc/WSLInterop}"
WSL_SYSTEMD_DIR="${GSG_WSL_SYSTEMD_DIR:-/run/systemd/system}"

# ^ invariant one stderr line per run, only when a seam is set and makes this a WSL run => a plain fixture leaves asserted stderr alone
WSL_ANNOUNCED=0
wsl_announce_overrides() {
    if [ "$WSL_ANNOUNCED" -eq 1 ]; then return 0; fi
    if [ -z "${GSG_WSL_OSRELEASE:-}${GSG_WSL_INTEROP:-}${GSG_WSL_SYSTEMD_DIR:-}" ]; then return 0; fi
    WSL_ANNOUNCED=1
    printf '%s: TEST OVERRIDE active (GSG_WSL_OSRELEASE=[%s] GSG_WSL_INTEROP=[%s] GSG_WSL_SYSTEMD_DIR=[%s]); the WSL kernel files are read from there\n' \
        "$GSG_NAME" "${GSG_WSL_OSRELEASE:-}" "${GSG_WSL_INTEROP:-}" "${GSG_WSL_SYSTEMD_DIR:-}" >&2
}

# ^ invariant sets REPLY = the first line of the kernel release file as it is; "" when the file is absent or unreadable; prints nothing
wsl_kernel_text() {
    local line=""
    REPLY=""
    { IFS= read -r line <"$WSL_OSRELEASE_FILE"; } 2>/dev/null || true
    REPLY="$line"
}

# ^ invariant rc 0 = the kernel files say WSL; read as data, uname must say Linux (Darwin and Git for Windows never are)
# ^ why microsoft in any case or the interop file, not WSL_DISTRO_NAME; the variable is not set at all on WSL 1 (#31 probe)
wsl_is() {
    local found=1
    if [ "$(uname -s)" != Linux ]; then return 1; fi
    wsl_kernel_text
    case "${REPLY,,}" in
        *microsoft*) found=0 ;;
        *) if [ -e "$WSL_INTEROP_FILE" ]; then found=0; fi ;;
    esac
    if [ "$found" -eq 0 ]; then wsl_announce_overrides; fi
    return "$found"
}

# ^ invariant sets REPLY = 1 when the raw kernel text holds Microsoft with a capital M (WSL 1), else 2; only meaningful after wsl_is succeeded
# ^ why the capital M, not a WSL2 suffix; real WSL 2 kernels exist without it (4.19.128-microsoft-standard)
wsl_version() {
    wsl_kernel_text
    case "$REPLY" in
        *Microsoft*) REPLY=1 ;;
        *) REPLY=2 ;;
    esac
}

# ^ invariant systemd runs when its run directory exists, as sd_booted tests; systemctl on PATH proves nothing (WSL 1 has the binary and pid 1 is init)
wsl_systemd_running() { [ -d "$WSL_SYSTEMD_DIR" ]; }

# ^ invariant $1 = 1 when --with-timer was given; rc 1 refuses before any change; WSL 1 gets no fix since [boot] does not exist there
# ^ external /etc/wsl.conf [boot] systemd=true needs WSL 2 on Windows 11 or Server 2022 (Microsoft wsl-config), followed by wsl --shutdown in Windows
wsl_check_timer() {
    if [ "$1" -ne 1 ] || ! wsl_is || wsl_systemd_running; then return 0; fi
    wsl_version
    if [ "$REPLY" -eq 1 ]; then
        printf '%s: --with-timer is not available on WSL 1: it has no systemd, and the weekly timer is a systemd user timer; install without --with-timer and run %s doctor by hand; nothing was changed\n' \
            "$GSG_NAME" "$GSG_NAME" >&2
        return 1
    fi
    printf '%s: --with-timer needs systemd, and it is not running in this WSL distribution; nothing was changed. Put this in /etc/wsl.conf:\n[boot]\nsystemd=true\n' "$GSG_NAME" >&2
    printf '%s: then run wsl --shutdown in Windows, open the distribution again and repeat the install (the [boot] section needs Windows 11 or Windows Server 2022)\n' "$GSG_NAME" >&2
    return 1
}

# ^ external Windows refuses to rename a directory with a running script in it (probed)
# ^ external renaming the directory of a running script fails on WSL 1 (4.4.0-20348-Microsoft, rc 1) and works on WSL 2 (6.18.54.1-microsoft-standard-WSL2)
# ^ see doc:docs/platforms.md#wsl-windows-subsystem-for-linux (run 42237326449)
install_pins_running_script() {
    if tools_is_windows; then return 0; fi
    if ! wsl_is; then return 1; fi
    wsl_version
    [ "$REPLY" -eq 1 ]
}

# ^ invariant a Windows git on a WSL PATH is a separate setup; the notice names it and says what covers it; never fails the install
# ^ why git.exe by its own name, not git; install_collect_gits looks for git and never sees the Windows one (probed on WSL 1, #31)
# ^ coupled the lookup is install_find_bin of lib/install.sh, the one place allowed to call type -P
install_wsl_notice() {
    if ! wsl_is; then return 0; fi
    if ! install_find_bin git.exe; then return 0; fi
    printf '%s: note: WSL and Windows are two separate git setups. %s is a Windows git: commits made with it are not covered by this install, which scans commits made with git inside this distribution only. To cover them run install in Git for Windows bash (docs/platforms.md#wsl-windows-subsystem-for-linux)\n' \
        "$GSG_NAME" "$REPLY" >&2
}
