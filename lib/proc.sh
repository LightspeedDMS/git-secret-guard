# shellcheck shell=bash

# ^ external Windows means Git for Windows bash (uname -s MINGW64_NT-*); no setsid, no process groups, native .exe scanners
proc_is_windows() {
    case "$(uname -s)" in
        MINGW64_NT-*) return 0 ;;
    esac
    return 1
}

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

# ^ invariant proc_start_runner <scanner> <scan-dir> <work-dir> <pid-var> <group-var> sets the two caller variables
# ^ invariant Linux group = runner pid (setsid); Windows has no groups, the same pid names the root of the tree proc_stop_group walks
# ^ security "$SETSID_BIN" comes from settings, not PATH => a planted setsid earlier on PATH cannot replace the runner start
proc_start_runner() {
    local scanner="$1" scan_dir="$2" work_dir="$3" pid_var="$4" group_var="$5" pid
    if proc_is_windows; then
        "$BASH" "$SHARE/lib/run-scanner.sh" "$scanner" "$scan_dir" "$work_dir" &
        pid=$!
        printf -v "$pid_var" '%s' "$pid"
        printf -v "$group_var" '%s' "$pid"
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
    local pgid="$1" pid="$2" i win
    local -a targets=()
    # ^ hazard TERM on the Windows runner leaves the native scanner running, and a survivor keeps the work dir busy => every process, no grace period
    # ^ hazard Windows reuses pids => the walk runs only as long as the runner is still the hook's unreaped child
    # ^ security "$TASKKILL_BIN" comes from settings, not PATH; MSYS_NO_PATHCONV keeps /T /F /PID from being rewritten as paths
    if proc_is_windows; then
        if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
            while IFS= read -r win; do targets+=(/PID "$win"); done < <(proc_windows_tree "$pid")
            if [ "${#targets[@]}" -gt 0 ]; then MSYS_NO_PATHCONV=1 "${TASKKILL_BIN:-}" /T /F "${targets[@]}" >/dev/null 2>&1; fi
            kill -KILL "$pid" 2>/dev/null
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
