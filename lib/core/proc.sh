# shellcheck shell=bash

# ^ security a missing common.sh stops the load, never reads as not Windows; every sourcer loads lib/core/common.sh first
if ! declare -F gsg_is_windows >/dev/null; then
    printf 'lib/core/proc.sh: lib/core/common.sh must be sourced first\n' >&2
    return 1
fi

# ^ external Windows means Git for Windows bash (uname -s MINGW64_NT-*); no setsid, no process groups, native .exe scanners
# ^ invariant needs lib/core/common.sh loaded first (the hook and the CLI load it first); the answer is the one gsg_is_windows keeps for the process
proc_is_windows() { gsg_is_windows; }

GSG_PROC_MAX_TREE=512

# ^ external MSYS exec replaces the Windows process and keeps the MSYS pid => a Windows pid read at start goes stale and taskkill /T stops at the gap (probed)
# ^ invariant prints the current Windows pid of $1 and of every descendant, from the parent links in /proc (or the table at $2); bounded by GSG_PROC_MAX_TREE
proc_windows_tree() {
    local root="$1" table="${2:-/proc}" dir p parent win i
    local -A kids=() wins=()
    local -a queue=("$root") more=()
    for dir in "$table"/[0-9]*; do
        p="${dir##*/}"
        { read -r parent <"$dir/ppid" && read -r win <"$dir/winpid"; } 2>/dev/null || continue
        kids[$parent]+=" $p"
        wins[$p]="$win"
    done
    for ((i = 0; i < ${#queue[@]} && i < GSG_PROC_MAX_TREE; i++)); do
        p="${queue[$i]}"
        if [[ ${wins[$p]:-} =~ ^[0-9]+$ ]]; then printf '%s\n' "${wins[$p]}"; fi
        read -r -a more <<<"${kids[$p]:-}"
        queue+=("${more[@]}")
    done
}

# ^ invariant proc_start_group <pid-var> <group-var> <command> [args...] starts the command as a stoppable unit and sets the two caller variables
# ^ invariant Linux group = unit pid (setsid); Windows has no groups, the same pid names the root of the tree proc_stop_group walks
# ^ security "$SETSID_BIN" comes from settings, not PATH => a planted setsid earlier on PATH cannot replace the unit start
proc_start_group() {
    local pid_var="$1" group_var="$2" pid
    shift 2
    if proc_is_windows; then
        "$@" &
    else
        "$SETSID_BIN" "$@" &
    fi
    pid=$!
    printf -v "$pid_var" '%s' "$pid"
    printf -v "$group_var" '%s' "$pid"
}

SUP_PID="" SUP_PGID="" SUP_SIGNAL=0

# ^ invariant a second signal during the stop is ignored => the stop and the wait for the worker's cleanup are never cut short
proc_supervise_stop() {
    trap '' HUP INT TERM
    proc_stop_worker "$SUP_PGID" "$SUP_PID"
}

# ^ why a worker unit and a polling shell, not the scan in this shell; bash runs a trap after its foreground child returns
# ^ hazard a blocking wait lets bash's SIGINT handler rewrite PIPESTATUS in signal context, a second trapped signal frees it twice, SIGABRT
# ^ invariant a foreground sleep polls kill -0 => the trap runs within one tick, or at once when Ctrl-C stops the sleep; past the cap wait blocks as before
GSG_PROC_SUPERVISE_TICK_S=0.1
GSG_PROC_SUPERVISE_MAX_TICKS=36000
# ^ invariant proc_supervise <command> [args...] runs the command as a unit and returns its status; HUP, INT and TERM stop the unit and exit 129, 130, 143
# ^ order a signal before the pid is known is acted on right after => no unit runs unseen; a status above 128 keeps the group for the exit trap
proc_supervise() {
    local rc i
    SUP_PID="" SUP_PGID="" SUP_SIGNAL=0
    trap proc_supervise_stop EXIT
    trap 'SUP_SIGNAL=129' HUP
    trap 'SUP_SIGNAL=130' INT
    trap 'SUP_SIGNAL=143' TERM
    proc_start_group SUP_PID SUP_PGID "$@"
    trap 'trap "" HUP INT TERM; exit 129' HUP
    trap 'trap "" HUP INT TERM; exit 130' INT
    trap 'trap "" HUP INT TERM; exit 143' TERM
    if [ "$SUP_SIGNAL" -ne 0 ]; then exit "$SUP_SIGNAL"; fi
    # ^ why a failing sleep ends the poll, not a retry; a missing sleep falls through to the blocking wait and never spins
    for ((i = 0; i < GSG_PROC_SUPERVISE_MAX_TICKS; i++)); do
        kill -0 "$SUP_PID" 2>/dev/null || break
        sleep "$GSG_PROC_SUPERVISE_TICK_S" || break
    done
    # ^ external bash prints a "Terminated" job message for a signalled child; the status is passed on instead
    { wait "$SUP_PID"; } 2>/dev/null
    rc=$?
    SUP_PID=""
    if [ "$rc" -le 128 ]; then SUP_PGID=""; fi
    return "$rc"
}

# ^ invariant proc_start_runner <scanner> <scan-dir> <work-dir> <pid-var> <group-var> sets the two caller variables
proc_start_runner() {
    proc_start_group "$4" "$5" "$BASH" "$SHARE/lib/scan/run-scanner.sh" "$1" "$2" "$3"
}

# ^ invariant a stop gives its groups GSG_PROC_GRACE_TICKS x 0.1 s (5 s); the worker's cleanup waits for all its groups in one such grace
# ^ invariant the supervisor waits GSG_PROC_WORKER_GRACE_TICKS (15 s), above the grace plus rm and the Windows retry => no KILL of a cleaning worker
GSG_PROC_GRACE_TICKS=50
GSG_PROC_WORKER_GRACE_TICKS=150

# ^ invariant TERM only, nothing waits => a caller signals every group before it waits for any, the groups stop side by side
proc_signal_group() {
    local pgid="$1" pid="$2"
    if proc_is_windows || [ -z "$pgid" ]; then return 0; fi
    kill -TERM -- "-$pgid" 2>/dev/null || { [ -z "$pid" ] || kill -TERM "$pid" 2>/dev/null; }
    return 0
}

# ^ invariant proc_wait_groups <ticks> <pgid> <pid> [<pgid> <pid>...] polls all groups together for at most ticks x 0.1 s and KILLs what is left
# ^ why polling, not wait first; a child ignoring TERM keeps wait blocked and the KILL is never reached
proc_wait_groups() {
    local ticks="$1" i k alive win
    local -a pgids=() pids=() targets=()
    shift
    while [ "$#" -ge 2 ]; do
        pgids+=("$1") pids+=("$2")
        shift 2
    done
    # ^ hazard TERM on the Windows runner leaves the native scanner running, and a survivor keeps the work dir busy => every process, no grace period
    # ^ hazard Windows reuses pids => the walk runs only as long as the runner is still the hook's unreaped child
    # ^ security "$TASKKILL_BIN" comes from settings, not PATH; MSYS_NO_PATHCONV keeps /T /F /PID from being rewritten as paths
    if proc_is_windows; then
        for ((k = 0; k < ${#pids[@]}; k++)); do
            if [ -z "${pids[k]}" ] || ! kill -0 "${pids[k]}" 2>/dev/null; then continue; fi
            targets=()
            while IFS= read -r win; do targets+=(/PID "$win"); done < <(proc_windows_tree "${pids[k]}")
            if [ "${#targets[@]}" -gt 0 ]; then MSYS_NO_PATHCONV=1 "${TASKKILL_BIN:-}" /T /F "${targets[@]}" >/dev/null 2>&1; fi
            kill -KILL "${pids[k]}" 2>/dev/null
            wait "${pids[k]}" 2>/dev/null
        done
        return 0
    fi
    for ((i = 0; i < ticks; i++)); do
        alive=0
        for ((k = 0; k < ${#pgids[@]}; k++)); do
            if [ -z "${pgids[k]}" ]; then continue; fi
            if [ -n "${pids[k]}" ] && ! proc_running "${pids[k]}"; then
                wait "${pids[k]}" 2>/dev/null
                pids[k]=""
            fi
            if [ -z "${pids[k]}" ] && ! kill -0 -- "-${pgids[k]}" 2>/dev/null; then
                pgids[k]=""
                continue
            fi
            alive=1
        done
        if [ "$alive" -eq 0 ]; then return 0; fi
        sleep 0.1
    done
    for ((k = 0; k < ${#pgids[@]}; k++)); do
        if [ -z "${pgids[k]}" ]; then continue; fi
        kill -KILL -- "-${pgids[k]}" 2>/dev/null || { [ -z "${pids[k]}" ] || kill -KILL "${pids[k]}" 2>/dev/null; }
        if [ -n "${pids[k]}" ]; then wait "${pids[k]}" 2>/dev/null; fi
    done
    return 0
}

# ^ invariant runner pid = its process group id (setsid) => kill -- -pgid reaches runner, timeout and scanner; arg 3 overrides the tick count
# ^ invariant tpgid/gpgid are never cleared => grandchildren of a timed-out scanner still get stopped
# ^ hazard signal before the child's setsid() => no group yet; the fallback kills the pid, only for an unreaped child
proc_stop_group() {
    proc_signal_group "$1" "$2"
    proc_wait_groups "${3:-$GSG_PROC_GRACE_TICKS}" "$1" "$2"
}

# ^ invariant rc 0 = the pid is alive and not a zombie; a zombie child answers kill -0 until it is waited for, ps tells the state
# ^ hazard ps missing or failing => alive; the caller's deadline ends the wait, never a blocking wait on a live child
proc_running() {
    local state
    kill -0 "$1" 2>/dev/null || return 1
    state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 0
    state="${state//[[:space:]]/}"
    [ -n "$state" ] && [ "${state:0:1}" != Z ]
}

# ^ why TERM and the worker's own trap, not a kill; the worker owns the work dir with the staged added lines and the groups of both scanners
# ^ invariant Linux, TERM to the worker's group reaches its foreground git and awk and the worker itself, whose trap runs cleanup
# ^ invariant Windows has no groups and /F skips cleanup => descendants die first, TERM runs the trap, after the worker grace proc_stop_group ends the unit
proc_stop_worker() {
    local pgid="$1" pid="$2" table="${3:-/proc}" i win rootwin=""
    local -a targets=()
    if ! proc_is_windows; then
        proc_stop_group "$pgid" "$pid" "$GSG_PROC_WORKER_GRACE_TICKS"
        return 0
    fi
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then return 0; fi
    # ^ order TERM before taskkill => the trap is pending when the foreground child dies; no false failure line, no next child
    kill -TERM "$pid" 2>/dev/null
    # ^ hazard no Windows pid for the worker => /F could take the worker with its descendants and skip cleanup; TERM and the deadline decide
    { read -r rootwin <"$table/$pid/winpid"; } 2>/dev/null
    if [ -n "$rootwin" ]; then
        while IFS= read -r win; do
            if [ "$win" != "$rootwin" ]; then targets+=(/PID "$win"); fi
        done < <(proc_windows_tree "$pid" "$table")
    fi
    if [ "${#targets[@]}" -gt 0 ]; then MSYS_NO_PATHCONV=1 "${TASKKILL_BIN:-}" /T /F "${targets[@]}" >/dev/null 2>&1; fi
    for ((i = 0; i < GSG_PROC_WORKER_GRACE_TICKS; i++)); do
        if ! kill -0 "$pid" 2>/dev/null; then
            wait "$pid" 2>/dev/null
            return 0
        fi
        sleep 0.1
    done
    proc_stop_group "$pgid" "$pid"
}
