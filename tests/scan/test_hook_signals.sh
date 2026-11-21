#!/usr/bin/env bash
# ^ see doc:docs/scan.md#signals; a HUP or TERM sent to the hook's own pid must not wait for a foreground git call
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ why 3000 ms, not less; the stop is TERM, a wait and the work dir removal, and a loaded machine needs headroom; the slow git alone would take SIG_SLOW_S
SIG_PROMPT_MS=3000
SIG_SLOW_S=30
# ^ invariant the slow git must show up within SIG_START_TRIES x SIG_POLL_S seconds (15), or the test fails its sanity check
SIG_START_TRIES=150
SIG_POLL_S=0.1
SIG_RECHECK_S=1

SIGDUR=""
workdirs() { find "$TEST_WORK_BASE" -maxdepth 1 -name 'git-secret-guard.*' 2>/dev/null; }
# ^ security the whole command line, dot escaped, on this test's own random duration => stand-ins of a concurrent run are not counted
slow_processes() { pgrep -f -- "^sleep ${SIGDUR//./\\.}\$" | wc -l; }

# ^ why a git earlier on PATH, not a stub in the product; git run by hand does not prepend its exec-path => the hook finds the slow one first
# ^ invariant arg 1 = test name, 2 = the git subcommand to hang, matched against every argument; each other call runs the real git
sig_begin() {
    new_repo "$1" || return 1
    use_stubs "" || return 1
    SIGDUR="$SIG_SLOW_S.$RANDOM"
    mkdir -p -- "$SANDBOX/slowbin" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/bash\nfor a in "$@"; do\n    if [ "$a" = %q ]; then exec sleep %s; fi\ndone\nexec %q "$@"\n' "$2" "$SIGDUR" "$GIT" >"$SANDBOX/slowbin/git" || return 1
    chmod 755 "$SANDBOX/slowbin/git" || return 1
    set_env PATH="$SANDBOX/slowbin:$REAL_HOME/.local/bin:$TEST_BASE_PATH"
}

# ^ invariant ready = the slow processes are counted, or with SIG_READY_BYTES set, the work dir holds this many bytes => a marker for runs with no sleeper
sig_ready() {
    local bytes
    if [ -n "${SIG_READY_BYTES:-}" ]; then
        bytes="$(du -sb -- "$TEST_WORK_BASE"/git-secret-guard.* 2>/dev/null | head -n 1)"
        [ "${bytes%%[^0-9]*}" -ge "$SIG_READY_BYTES" ] 2>/dev/null
        return
    fi
    [ "$(slow_processes)" -ge "${SIG_START_COUNT:-1}" ]
}

# ^ invariant arg 1 = the signal, args 2.. = the hook's own arguments; HUP and TERM go to the hook pid only, INT to its whole group like a terminal's Ctrl-C
# ^ invariant sets SIG_RC and SIG_MS; the run is killed in full if the signal cannot be sent => no 30 s sleeper outlives a failing test
# ^ external a background job starts with SIGINT ignored, env --default-signal restores it; git runs hooks with SIGPIPE ignored, --ignore-signal=PIPE does too
sig_start() {
    local tries=0
    "$TEST_SETSID" env --default-signal=INT,TERM,HUP --ignore-signal=PIPE -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SHARE/hooks/secret-scan" "$@" >"$SANDBOX/.out" 2>"$SANDBOX/.err" &
    HOOK_PGID=$!
    while ! sig_ready && [ "$tries" -lt "$SIG_START_TRIES" ]; do sleep "$SIG_POLL_S"; tries=$((tries + 1)); done
    if ! sig_ready; then
        fail "sanity: the slow processes never started"
        sig_reap
        return 1
    fi
}

sig_run() {
    local sig="$1" t0 t1 target hpid
    shift
    sig_start "$@" || return 1
    hpid="$HOOK_PGID"
    target="$hpid"
    if [ "$sig" = INT ]; then target="-$hpid"; fi
    t0="$(date +%s%N)"
    if ! kill "-$sig" -- "$target"; then
        fail "could not send SIG$sig to $target"
        sig_reap
        return 1
    fi
    # ^ invariant SIG_SECOND, when set, follows at once to the hook pid; a hook already gone is no failure
    if [ -n "${SIG_SECOND:-}" ]; then kill "-$SIG_SECOND" -- "$hpid" 2>/dev/null; fi
    wait "$hpid" 2>/dev/null
    SIG_RC=$?
    t1="$(date +%s%N)"
    SIG_MS=$(((t1 - t0) / 1000000))
}

# ^ invariant kills whatever is left of the run's group and of the slow git; harmless when nothing is left
sig_reap() {
    kill -KILL -- "-$HOOK_PGID" 2>/dev/null
    pkill -KILL -f -- "^sleep ${SIGDUR//./\\.}\$" 2>/dev/null
    wait "$HOOK_PGID" 2>/dev/null
    return 0
}

# ^ invariant the checks every signal test shares, prompt exit, the right status, nothing of the run left, the work dir gone and still gone later
sig_check() {
    local want="$1" what="$2"
    # ^ invariant want is one status or an alternation (143|129); two signals pending together run their traps in signal-number order, either may report
    [[ $SIG_RC =~ ^($want)$ ]] || fail "$what: exit status: expected [$want] got [$SIG_RC]"
    [ "$SIG_MS" -lt "$SIG_PROMPT_MS" ] || fail "$what: the hook took $SIG_MS ms; it waited for the foreground git"
    assert_eq "$(slow_processes)" 0 "$what: the slow git is gone"
    assert_eq "$(pgrep -g "$HOOK_PGID" | wc -l)" 0 "$what: nothing is left in the hook's process group"
    # ^ why by command line too, not only by group; the worker has a session of its own, pgrep -g cannot see it
    assert_eq "$(pgrep -f -- "$SHARE/hooks/secret-scan" | wc -l)" 0 "$what: no hook process, supervisor or worker, survives"
    assert_empty "$(workdirs)" "$what: work dir removed"
    sleep "$SIG_RECHECK_S"
    assert_eq "$(slow_processes)" 0 "$what: still no survivor later"
    assert_empty "$(workdirs)" "$what: work dir stays gone"
    sig_reap
}

# ^ invariant arg 1 = test name, 2 = signal, 3 = the hanging subcommand, 4 = expected status
lines_signal_test() {
    sig_begin "$1" "$3" || return 1
    stage_file a.txt one || return 1
    sig_run "$2" || return 1
    sig_check "$4" "$2 during git $3"
}

test_term_to_the_hook_pid_stops_a_slow_write_tree_at_once() { lines_signal_test wt TERM write-tree 143; }
test_hup_to_the_hook_pid_stops_a_slow_write_tree_at_once() { lines_signal_test wth HUP write-tree 129; }
test_term_to_the_hook_pid_stops_a_slow_diff_tree_at_once() { lines_signal_test dt TERM diff-tree 143; }
test_hup_to_the_hook_pid_stops_a_slow_diff_tree_at_once() { lines_signal_test dth HUP diff-tree 129; }
test_ctrl_c_to_the_whole_group_stops_a_slow_diff_tree_at_once() { lines_signal_test dti INT diff-tree 130; }

# ^ invariant the commit-msg run, a message with a cut line makes the hook run git diff --cached to compare the text below it
message_signal_test() {
    sig_begin "$1" diff || return 1
    enable_message_hook || return 1
    stage_file a.txt one || return 1
    printf 'subject\n\n; Please enter the commit message.\n; ------------------------ >8 ------------------------\n; Do not modify.\n+one\n' >"$SANDBOX/msg" || return 1
    sig_run "$2" "$SANDBOX/msg" || return 1
    sig_check "$3" "$2 during the message run's git diff"
}

test_term_to_the_hook_pid_stops_a_slow_message_run_git_diff_at_once() { message_signal_test msgt TERM 143; }
test_hup_to_the_hook_pid_stops_a_slow_message_run_git_diff_at_once() { message_signal_test msgh HUP 129; }
test_ctrl_c_to_the_whole_group_stops_a_slow_message_run_git_diff_at_once() { message_signal_test msgi INT 130; }

# ^ why long hunks, not many one-line files; a diff cut by SIGPIPE ends inside a hunk almost surely, awk keeps up with git and reads the cut at once
# ^ invariant ready = SIG_READY_BYTES in the run's work dir, about 1% of what is staged => the stop lands inside the extraction
SIG_REAL_DIFF_FILES=60
SIG_REAL_DIFF_LINES=40000
SIG_REAL_DIFF_READY=1000000
real_diff_begin() {
    local i
    sig_begin "$1" no-such-subcommand || return 1
    SIG_READY_BYTES="$SIG_REAL_DIFF_READY"
    seq 1 "$SIG_REAL_DIFF_LINES" | sed 's/^/added line number /' >"f0.txt" || return 1
    for ((i = 1; i < SIG_REAL_DIFF_FILES; i++)); do cp -- f0.txt "f$i.txt" || return 1; done
    gitx add -- . || return 1
}

# ^ invariant a stop is not an extraction failure => no extraction error line, the commit is refused, nothing of the run, awk included, is left
real_diff_signal_test() {
    local err rc
    real_diff_begin "$1" || return 1
    sig_run "$2" || { SIG_READY_BYTES=""; return 1; }
    SIG_READY_BYTES=""
    sig_check "$3" "$2 during real diff-tree output"
    rc=$?
    err="$(<"$SANDBOX/.err")"
    assert_not_contains "$err" "extract:" "$2 during real diff-tree output: no false extraction error"
    assert_eq "$(pgrep -f -- "$SHARE/lib/scan/extract.awk" | wc -l)" 0 "$2 during real diff-tree output: no awk left"
    return "$rc"
}

test_term_during_real_diff_tree_output_prints_no_extraction_error() { real_diff_signal_test rdt TERM 143; }
test_hup_during_real_diff_tree_output_prints_no_extraction_error() { real_diff_signal_test rdh HUP 129; }
test_ctrl_c_during_real_diff_tree_output_prints_no_extraction_error() { real_diff_signal_test rdi INT 130; }

# ^ invariant arg 1 = test name, 2 = the first signal, 3 = the second, 4 = the expected status; the second follows the first at once
double_signal_test() {
    SIG_SECOND="$3"
    lines_signal_test "$1" "$2" write-tree "$4"
    local rc=$?
    SIG_SECOND=""
    return "$rc"
}

test_a_hup_right_after_a_term_cannot_cut_the_stop_short() { double_signal_test dbl1 TERM HUP '143|129'; }
test_a_term_right_after_a_term_cannot_cut_the_stop_short() { double_signal_test dbl2 TERM TERM 143; }
test_a_hup_right_after_ctrl_c_leaves_no_work_dir_behind() { double_signal_test dbl3 INT HUP '130|129'; }

# ^ why SIGKILL on the worker only, not the supervisor too; the supervisor must still stop the worker's foreground git and exit with its status
# ^ invariant the worker is the newest process whose command line holds the hook path; 137 is 128 + KILL (9)
SIG_KILLED_RC=$((128 + 9))
test_a_killed_worker_does_not_leave_its_foreground_git_running() {
    local wpid
    sig_begin killw write-tree || return 1
    stage_file a.txt one || return 1
    sig_start || return 1
    wpid="$(pgrep -f -- "$SHARE/hooks/secret-scan" | sort -n | tail -n 1)"
    if [ -z "$wpid" ] || [ "$wpid" = "$HOOK_PGID" ] || ! kill -KILL "$wpid"; then
        fail "sanity: the worker could not be found and killed"
        sig_reap
        return 1
    fi
    wait "$HOOK_PGID" 2>/dev/null
    assert_eq "$?" "$SIG_KILLED_RC" "the supervisor exits with the worker's status"
    assert_eq "$(slow_processes)" 0 "the git the killed worker was running is stopped"
    # ^ hazard a worker killed with KILL runs no cleanup => its work dir stays; removed here to keep the shared sandbox clean
    rm -rf -- "$TEST_WORK_BASE"/git-secret-guard.*
    sig_reap
}

# ^ invariant a unit script sources the sandbox copy of lib/core/proc.sh and runs the code of arg 1; unit_run adds a timeout longer than any bound it uses
# ^ invariant a backgrounded run calls unit_command with no timeout => $! is the bash running the code and a signal reaches it
SIG_UNIT_TIMEOUT_S=25
SIG_GRACE_MIN_MS=4000
# ^ why 14000 ms, not 9000; each tick adds kill -0 and ps to its sleep, the macOS runner took 9603 ms for 50; still under the supervisor's 15 s
SIG_GRACE_MAX_MS=14000
SIG_RACE_HOLD_S=1
SIG_RACE_SIGNAL_AFTER_S=0.4
SIG_SETTLE_S=0.5
unit_write() { printf 'source "%s/lib/core/common.sh" && source "%s/lib/core/proc.sh" || exit 9\n%s\n' "$SHARE" "$SHARE" "$1" >"$SANDBOX/unit.sh"; }
unit_command() { UNIT_CMD=(env -i "${GSG_ENV[@]}" SETSID_BIN="$TEST_SETSID" "$@" bash "$SANDBOX/unit.sh" "$SIGDUR"); }
unit_run() {
    unit_command "$TEST_TIMEOUT" "$SIG_UNIT_TIMEOUT_S"
    "${UNIT_CMD[@]}" >"$SANDBOX/.out" 2>"$SANDBOX/.err"
}

SIG_TERM_RC=$((128 + 15))
NS_PER_MS=1000000
kill_sleepers() { pkill -KILL -f -- "^sleep ${SIGDUR//./\\.}\$" 2>/dev/null; return 0; }

# ^ why the pid record is held by a printf function, not a sleep elsewhere; the window is the gap between the start and printf -v of proc_start_group
test_a_signal_before_the_worker_pid_is_recorded_still_stops_the_worker() {
    local spid t0 t1 ms
    new_repo race || return 1
    SIGDUR="$SIG_SLOW_S.$RANDOM"
    unit_write "printf() { case \"\${1:-}\" in -v) sleep $SIG_RACE_HOLD_S ;; esac; builtin printf \"\$@\"; }
proc_supervise bash -c 'sleep \"\$1\"' _ \"\$1\"
echo \"rc=\$?\"" || return 1
    unit_command
    "${UNIT_CMD[@]}" >"$SANDBOX/.out" 2>"$SANDBOX/.err" &
    spid=$!
    sleep "$SIG_RACE_SIGNAL_AFTER_S"
    t0="$(date +%s%N)"
    kill -TERM "$spid" || { fail "could not signal the supervisor"; kill_sleepers; return 1; }
    wait "$spid" 2>/dev/null
    assert_eq "$?" "$SIG_TERM_RC" "the supervisor exits on the signal"
    t1="$(date +%s%N)"
    ms=$(((t1 - t0) / NS_PER_MS))
    [ "$ms" -lt "$SIG_PROMPT_MS" ] || fail "the supervisor took $ms ms"
    sleep "$SIG_RECHECK_S"
    assert_eq "$(slow_processes)" 0 "the worker started before its pid was recorded is stopped"
    kill_sleepers
}

# ^ hazard bash's SIGINT handler updates PIPESTATUS in signal context during wait, a second trapped signal longjmps out of it, double free, SIGABRT
# ^ invariant the supervisor polls with a foreground sleep => a direct sleep child exists during the worker's run; the worker's own sleep is a grandchild
SIG_POLL_WAIT_TICKS=30
SIG_POLL_INTERVAL_S=0.1
test_the_supervisor_polls_with_a_foreground_sleep_never_a_blocking_wait() {
    local spid i found=0
    new_repo poll || return 1
    SIGDUR="$SIG_SLOW_S.$RANDOM"
    # ^ why a second command in the worker, not a lone sleep; bash would exec a lone sleep and the worker itself would be the supervisor's direct sleep child
    unit_write "proc_supervise bash -c 'sleep \"\$1\"; sleep 0' _ \"\$1\"" || return 1
    unit_command
    "${UNIT_CMD[@]}" >"$SANDBOX/.out" 2>"$SANDBOX/.err" &
    spid=$!
    for ((i = 0; i < SIG_POLL_WAIT_TICKS; i++)); do
        if pgrep -P "$spid" -x sleep >/dev/null; then found=1; break; fi
        sleep "$SIG_POLL_INTERVAL_S"
    done
    kill -TERM "$spid" || { fail "could not signal the supervisor"; kill_sleepers; return 1; }
    wait "$spid" 2>/dev/null
    kill_sleepers
    assert_eq "$found" 1 "the supervisor has a foreground sleep child while the worker runs"
}

# ^ why a child ignoring TERM, not a plain sleeper; proc_stop_group waited for the worker before its bounded escalation and never reached the KILL
test_a_worker_that_ignores_term_is_killed_after_the_grace_period() {
    local ms
    new_repo ignore || return 1
    SIGDUR="$SIG_SLOW_S.$RANDOM"
    unit_write "proc_start_group p g bash -c 'trap \"\" TERM; sleep \"\$1\"' _ \"\$1\"
sleep $SIG_SETTLE_S
t0=\$(date +%s%N)
proc_stop_group \"\$g\" \"\$p\"
echo \"ms=\$(( (\$(date +%s%N) - t0) / $NS_PER_MS ))\"" || return 1
    unit_run
    ms="$(sed -n 's/^ms=//p' "$SANDBOX/.out")"
    [[ $ms =~ ^[0-9]+$ ]] || { fail "no timing printed (stderr: $(<"$SANDBOX/.err"))"; kill_sleepers; return 1; }
    [ "$ms" -ge "$SIG_GRACE_MIN_MS" ] && [ "$ms" -lt "$SIG_GRACE_MAX_MS" ] || fail "the stop took $ms ms; expected $SIG_GRACE_MIN_MS to $SIG_GRACE_MAX_MS (grace, then KILL)"
    assert_eq "$(slow_processes)" 0 "the TERM-ignoring child is gone"
    kill_sleepers
}

# ^ invariant a wrapper records the scanner's environment and runs the stand-in; GSG_SCAN_WORKER names the worker only
test_the_scanners_do_not_inherit_the_worker_marker() {
    new_repo marker || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/bash\nprintf "%%s\\n" "${GSG_SCAN_WORKER-unset}" >>%q\nexec %q "$@"\n' "$SANDBOX/marker.log" "$STUBS_DIR/trufflehog" >"$SANDBOX/tf-wrap" || return 1
    chmod 755 "$SANDBOX/tf-wrap" || return 1
    write_settings "$SANDBOX/tf-wrap" "$STUBS_DIR/betterleaks" "$TEST_JQ" || return 1
    stage_file a.txt one || return 1
    commit_cap "marker"
    assert_rc 0 commit
    assert_eq "$(<"$SANDBOX/marker.log")" unset "the scanner does not see the marker"
}

# ^ why 12000 ms, not the 3000 of the others; both scanner groups stop in one 5 s grace, one after the other 10 s would reach the supervisor's KILL
SIG_STUBBORN_MS=12000
test_two_scanners_that_ignore_term_are_stopped_before_the_work_dir_is_removed() {
    local keep_ms="$SIG_PROMPT_MS" rc
    sig_begin stubborn2 no-such-subcommand || return 1
    set_env STUB_TF_SLEEP="$SIGDUR" STUB_GL_SLEEP="$SIGDUR" STUB_TF_STUBBORN=1 STUB_GL_STUBBORN=1
    stage_file a.txt one || return 1
    SIG_START_COUNT=2
    SIG_PROMPT_MS="$SIG_STUBBORN_MS"
    sig_run TERM && sig_check 143 "TERM with two scanners ignoring TERM"
    rc=$?
    SIG_START_COUNT=1
    SIG_PROMPT_MS="$keep_ms"
    return "$rc"
}

run_file_tests
