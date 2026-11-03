# shellcheck shell=bash

# ^ external Windows means Git for Windows bash (uname -s MINGW64_NT-*); no setsid, no process groups, native .exe scanners
proc_is_windows() {
    case "$(uname -s)" in
        MINGW64_NT-*) return 0 ;;
    esac
    return 1
}

# ^ invariant proc_start_runner <scanner> <scan-dir> <work-dir> <pid-var> <group-var> sets the two caller variables; rc 1 when no Windows pid is readable
# ^ invariant Linux group = runner pid (setsid); Windows group = the runner's Windows pid, read from /proc/<pid>/winpid
# ^ security "$SETSID_BIN" comes from settings, not PATH => a planted setsid earlier on PATH cannot replace the runner start
proc_start_runner() {
    local scanner="$1" scan_dir="$2" work_dir="$3" pid_var="$4" group_var="$5" pid winpid
    if proc_is_windows; then
        "$BASH" "$SHARE/lib/run-scanner.sh" "$scanner" "$scan_dir" "$work_dir" &
        pid=$!
        printf -v "$pid_var" '%s' "$pid"
        winpid="$(cat "/proc/$pid/winpid" 2>/dev/null)" || winpid=""
        if [[ ! $winpid =~ ^[0-9]+$ ]]; then return 1; fi
        printf -v "$group_var" '%s' "$winpid"
        return 0
    fi
    "$SETSID_BIN" "$BASH" "$SHARE/lib/run-scanner.sh" "$scanner" "$scan_dir" "$work_dir" &
    pid=$!
    printf -v "$pid_var" '%s' "$pid"
    printf -v "$group_var" '%s' "$pid"
}

# ^ invariant runner pid = its process group id (setsid) => kill -- -pgid reaches runner, timeout and scanner
# ^ invariant tpgid/gpgid are never cleared => grandchildren of a timed-out scanner still get stopped
# ^ hazard signal before the child's setsid() => no group yet; the fallback kills the pid, only for an unreaped child
proc_stop_group() {
    local pgid="$1" pid="$2" i
    # ^ hazard TERM on the Windows runner leaves timeout and the native scanner running => taskkill /T /F on the whole tree, no grace period
    # ^ hazard Windows reuses pids => taskkill runs only while the runner is still the hook's unreaped child
    # ^ security "$TASKKILL_BIN" comes from settings, not PATH; MSYS_NO_PATHCONV keeps /T /F /PID from being rewritten as paths
    if proc_is_windows; then
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            if [ -z "$pgid" ] || ! MSYS_NO_PATHCONV=1 "${TASKKILL_BIN:-}" /T /F /PID "$pgid" >/dev/null 2>&1; then
                kill -KILL "$pid" 2>/dev/null
            fi
            wait "$pid" 2>/dev/null
        fi
        return 0
    fi
    if [ -z "$pgid" ]; then return 0; fi
    kill -TERM -- "-$pgid" 2>/dev/null || { [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null; }
    if [ -n "$pid" ]; then wait "$pid" 2>/dev/null; fi
    for ((i = 0; i < 50; i++)); do
        if ! kill -0 -- "-$pgid" 2>/dev/null; then return 0; fi
        sleep 0.1
    done
    kill -KILL -- "-$pgid" 2>/dev/null || { [ -z "$pid" ] || kill -KILL "$pid" 2>/dev/null; }
    return 0
}
