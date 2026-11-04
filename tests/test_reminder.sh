#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

MANY_REPOS=55
HOLD_SECONDS=600
WAIT_TRIES=150
POLL_SECONDS=0.1
SETTLE_SECONDS=1
REMINDER_HINT="  run git-secret-guard doctor for the full report"
RECHECK_FAILED_RE='^git-secret-guard: coverage re-check failed \(.*\); run git-secret-guard doctor$'

rec_file() { printf '%s' "$LC_STATE/findings"; }
rgit() { env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GIT" -C "$DR_ROOTS/$1" "${@:2}"; }
dr_disable() { gitx -C "$DR_ROOTS/$1" config hook.git-secret-guard.enabled false; }
dr_enable() { gitx -C "$DR_ROOTS/$1" config --unset hook.git-secret-guard.enabled; }
off_text() { printf 'disabled in local config: hook.git-secret-guard.enabled=false (%s/%s/.git/config); remove that key to cover this repository' "$DR_REAL" "$1"; }
spy_log() { if [ -f "$SANDBOX/spy.log" ]; then cat -- "$SANDBOX/spy.log"; fi; }
doctor_starts() { spy_log | grep -c 'git-secret-guard doctor --recheck' || true; }
proc_alive() {
    local st
    st="$(ps -p "$1" -o stat= 2>/dev/null)" || return 1
    st="${st//[[:space:]]/}"
    [ -n "$st" ] && [ "${st:0:1}" != Z ]
}

# ^ external the fixture tools only print their version; each wrapper forwards everything except --version to the test stand-in
# ^ why wrappers at the installed paths, not other settings; doctor reads the same settings and must still see the pinned versions
rem_scanners() {
    printf '#!/bin/sh\ncase "$1" in --version) echo "trufflehog 3.99.2"; exit 0 ;; esac\nexec %q "$@"\n' "$STUBS_DIR/trufflehog" >"$LC_BIN/trufflehog$LC_EXE" || return 1
    printf '#!/bin/sh\ncase "$1" in --version) echo "betterleaks version 1.9.0"; exit 0 ;; esac\nexec %q "$@"\n' "$STUBS_DIR/betterleaks" >"$LC_BIN/betterleaks$LC_EXE" || return 1
    chmod 755 "$LC_BIN/trufflehog$LC_EXE" "$LC_BIN/betterleaks$LC_EXE"
}

# ^ invariant the stand-in logs each setsid call and forwards it; for the re-check call it plays the failure named in $SANDBOX/spy.mode (exit2, kill, hang)
rem_spy_setsid() {
    mkdir -p -- "$SANDBOX/spy" || return 1
    rm -f -- "$SANDBOX/spy.log" "$SANDBOX/spy.mode" "$SANDBOX/spy.pid" || return 1
    cat >"$SANDBOX/spy/setsid" <<EOF || return 1
#!/bin/sh
echo "\$* ## \$(env | sed -n 's/^\(GIT_[A-Za-z_]*\)=.*/\1/p' | sort | tr '\n' ' ')" >>$SANDBOX/spy.log
case " \$* " in
    *" doctor --recheck "*)
        ls -A $TEST_WORK_BASE/git-secret-guard.*/ >$SANDBOX/spy.workls 2>&1
        if [ -f $SANDBOX/spy.mode ]; then
            case "\$(cat $SANDBOX/spy.mode)" in
                exit2) echo "internal doctor noise" >&2; exit 2 ;;
                kill) kill -KILL \$\$ ;;
                hang) echo \$\$ >$SANDBOX/spy.pid; exec $TEST_SETSID sleep $HOLD_SECONDS ;;
            esac
        fi
        ;;
esac
exec $TEST_SETSID "\$@"
EOF
    chmod 755 "$SANDBOX/spy/setsid" || return 1
    printf 'SETSID_BIN=%q\n' "$SANDBOX/spy/setsid" >>"$LC_DATA/settings"
}

# ^ invariant machine installed from the fixtures, repository a enabled and tracking f.txt, working scanner stand-ins
rem_begin() {
    dr_begin && rem_scanners && rem_spy_setsid && dr_repo a || return 1
    printf 'first\n' >"$DR_ROOTS/a/f.txt" || return 1
    rgit a add f.txt && rgit a commit -q --no-verify -m base
}

# ^ invariant a full doctor run records b as disabled (exit 1), a stays clean
rem_record_b() {
    dr_repo b && dr_disable b || return 1
    doctor
    [ "$RC" -eq 1 ] || { fail "setup: doctor exit $RC"; return 1; }
}

rem_begin_with_b_open() { rem_begin && rem_record_b; }

# ^ invariant commit -a (GIT_INDEX_FILE is set for the hook) of one more line in repository $1
rem_commit() {
    printf 'line %s\n' "$RANDOM" >>"$DR_ROOTS/$1/f.txt" || return 1
    run_cap rgit "$1" commit -q -a -m "next"
}

rec_date() { sed -n '2s/^time \(.\{10\}\).*/\1/p' "$(rec_file)"; }

# ^ invariant the stderr of a commit holds its own lines first, the reminder last; $1 = the exact reminder lines with the hint, $2 = label
assert_ends_with_reminder() {
    assert_contains "$ERR" "$1" "$2: the reminder block is printed whole"
    assert_eq "${ERR##*"$1"}" "" "$2: nothing follows the reminder"
}

assert_last_line_is_recheck_failure() {
    [[ $(tail -n 1 <<<"$ERR") =~ $RECHECK_FAILED_RE ]] || fail "$1: last line is not the re-check failure [$(tail -n 1 <<<"$ERR")]"
}

reminder_for_b() {
    printf 'git-secret-guard: 1 coverage problem still open (doctor run %s):\n  %s/b: %s\n%s' "$(rec_date)" "$DR_REAL" "$(off_text b)" "$REMINDER_HINT"
}

# ^ invariant $1 = a file holding doctor --recheck's stdout, $2 = a findings record; runs the formatter alone
run_report_reminder() {
    run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/common.sh" && source "$1/lib/report.sh" && report_reminder "$2" "$3"' _ "$GSG_PROJECT" "$1" "$2"
}

fake_record() { printf 'git-secret-guard findings 1\ntime 2026-03-04T05:06:07Z\n' >"$SANDBOX/rec"; }

test_a_passing_commit_reminds_of_an_open_problem_after_the_pass_line() {
    rem_begin_with_b_open || return 1
    rem_commit a
    assert_rc 0 "the commit passes"
    assert_empty "$OUT" "stdout stays empty"
    assert_pass_line_only "$(head -n 1 <<<"$ERR")" "first line is the pass line"
    assert_eq "$ERR" "$(head -n 1 <<<"$ERR")
$(reminder_for_b)" "pass line, then exactly the reminder"
    assert_eq "$(rgit a rev-list --count HEAD)" 3 "the commit was created"
}

test_the_reminder_repeats_on_every_commit() {
    rem_begin_with_b_open || return 1
    local i
    for i in 1 2 3; do
        rem_commit a
        assert_rc 0 "commit $i passes"
        assert_ends_with_reminder "$(reminder_for_b)" "commit $i"
    done
}

test_a_fixed_problem_stops_being_reminded_and_leaves_the_record() {
    rem_begin_with_b_open || return 1
    dr_enable b || return 1
    rem_commit a
    assert_rc 0 "the commit passes"
    assert_pass_line_only "$ERR" "no reminder, only the pass line"
    assert_empty "$(tail -n +3 "$(rec_file)")" "b is gone from the record"
    rem_commit a
    assert_pass_line_only "$ERR" "still only the pass line on the next commit"
    assert_eq "$(doctor_starts)" 1 "the emptied record starts no more re-checks"
}

test_a_blocked_commit_prints_its_findings_then_the_reminder_and_stays_blocked() {
    rem_begin_with_b_open || return 1
    local marker
    marker="$(new_marker)"
    set_env STUB_TF_FINDINGS="AWS|true|f.txt|2" STUB_MARKER="$marker"
    rem_commit a
    assert_rc 1 "the commit is refused as before"
    assert_contains "$ERR" "potential secret(s) in lines this commit adds" "findings block"
    assert_contains "$ERR" "git commit --no-verify" "bypass hint"
    assert_ends_with_reminder "$(reminder_for_b)" "blocked commit"
    assert_eq "$(rgit a rev-list --count HEAD)" 2 "no commit was created"
    no_leak "$marker"
}

test_a_nothing_to_scan_commit_also_reminds() {
    rem_begin_with_b_open || return 1
    run_cap rgit a commit -q --allow-empty -m empty
    assert_rc 0 "the empty commit passes"
    assert_contains "$ERR" "git-secret-guard: no added lines to scan" "nothing-to-scan line"
    assert_ends_with_reminder "$(reminder_for_b)" "empty commit"
}

test_a_commit_blocked_by_a_scanner_error_also_reminds() {
    rem_begin_with_b_open || return 1
    set_env STUB_TF_RC=3
    rem_commit a
    assert_rc 1 "blocked"
    assert_contains "$ERR" "did not complete" "the commit's own message"
    assert_ends_with_reminder "$(reminder_for_b)" "scanner error"
}

test_nothing_on_record_starts_no_process_and_prints_no_reminder() {
    rem_begin || return 1
    rem_commit a
    assert_rc 0 "no file: the commit passes"
    assert_pass_line_only "$ERR" "no file: only the pass line"
    mkdir -p -- "$LC_STATE" && : >"$(rec_file)" || return 1
    rem_commit a
    assert_rc 0 "empty file: the commit passes"
    assert_pass_line_only "$ERR" "empty file: only the pass line"
    assert_eq "$(doctor_starts)" 0 "doctor was never started"
}

test_a_failing_recheck_never_changes_a_passing_commit_and_prints_one_line() {
    rem_begin_with_b_open || return 1
    local mode
    for mode in exit2 kill; do
        printf '%s' "$mode" >"$SANDBOX/spy.mode" || return 1
        rem_commit a
        assert_rc 0 "$mode: the commit still passes"
        assert_eq "$(wc -l <<<"$ERR" | tr -d ' ')" 2 "$mode: pass line plus one re-check line"
        assert_last_line_is_recheck_failure "$mode"
        assert_not_contains "$ERR" "internal doctor noise" "$mode: doctor's own stderr is not copied"
    done
}

test_a_recheck_that_exits_2_on_a_damaged_record_leaves_a_blocked_commit_blocked() {
    rem_begin_with_b_open || return 1
    printf 'not a record\n' >"$(rec_file)" || return 1
    set_env STUB_TF_FINDINGS="AWS|true|f.txt|2"
    rem_commit a
    assert_rc 1 "still refused with its own exit"
    assert_contains "$ERR" "potential secret(s)" "findings block printed"
    assert_last_line_is_recheck_failure "damaged record"
}

test_a_missing_cli_in_the_share_dir_is_one_failed_recheck_line_not_a_failed_commit() {
    rem_begin_with_b_open || return 1
    rm -f -- "$LC_DATA/bin/git-secret-guard" || return 1
    rem_commit a
    assert_rc 0 "the commit passes"
    assert_last_line_is_recheck_failure "missing cli"
}

test_the_commits_environment_does_not_reach_the_recheck_of_other_repositories() {
    rem_begin_with_b_open || return 1
    local v recheck_line scanner_line
    rem_commit a
    assert_rc 0 "commit -a passes"
    assert_contains "$ERR" "$(off_text b)" "b's own config was read"
    recheck_line="$(spy_log | grep 'git-secret-guard doctor --recheck')"
    scanner_line="$(spy_log | grep 'run-scanner.sh' | head -n 1)"
    assert_contains "$recheck_line" "doctor --recheck" "the re-check call was observed in the spy log"
    assert_contains "$scanner_line" " GIT_INDEX_FILE " "sanity: the commit's own children do see GIT_INDEX_FILE"
    for v in $(gitx rev-parse --local-env-vars); do
        assert_not_contains "$recheck_line" " $v " "the re-check does not inherit $v"
    done
}

test_every_recorded_problem_is_rechecked_and_printed_with_no_limit() {
    rem_begin || return 1
    local i
    for i in $(seq 1 "$MANY_REPOS"); do
        dr_repo "r$i" && dr_disable "r$i" || return 1
    done
    doctor
    assert_rc 1 "setup: all disabled"
    rem_commit a
    assert_rc 0 "the commit passes"
    assert_contains "$ERR" "git-secret-guard: $MANY_REPOS coverage problems still open (doctor run $(rec_date)):" "count line"
    assert_eq "$(grep -c "coverage problems still open" <<<"$ERR")" 1 "one header"
    assert_eq "$(grep -c "^  $DR_REAL/r[0-9]*: disabled in local config" <<<"$ERR")" "$MANY_REPOS" "one line per problem"
}

test_the_scan_tree_and_scanner_outputs_are_gone_before_the_recheck_starts() {
    rem_begin_with_b_open || return 1
    local listing
    rm -f -- "$SANDBOX/spy.workls"
    set_env STUB_TF_FINDINGS="AWS|true|f.txt|2"
    rem_commit a
    assert_rc 1 "blocked by the finding"
    assert_file "$SANDBOX/spy.workls" "the stand-in listed the work dir"
    listing="$(<"$SANDBOX/spy.workls")"
    assert_contains "$listing" "recheck.out" "sanity: the listing is of the live work dir"
    assert_not_contains "$listing" "scan" "no scan tree or scan counts"
    assert_not_contains "$listing" ".rows" "no scanner rows"
    assert_not_contains "$listing" ".errors" "no scanner errors"
}

test_ctrl_c_during_the_recheck_leaves_no_process_behind() {
    rem_begin_with_b_open || return 1
    printf hang >"$SANDBOX/spy.mode" || return 1
    printf 'line\n' >>"$DR_ROOTS/a/f.txt" || return 1
    # ^ external a background job starts with SIGINT ignored; env --default-signal restores it as in a terminal Ctrl-C
    env --default-signal=INT,TERM -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GIT" -C "$DR_ROOTS/a" commit -q -a -m sig >/dev/null 2>&1 &
    local cpid=$! tries=0 rpid
    while [ ! -s "$SANDBOX/spy.pid" ] && [ "$tries" -lt "$WAIT_TRIES" ]; do sleep "$POLL_SECONDS"; tries=$((tries + 1)); done
    [ -s "$SANDBOX/spy.pid" ] || { fail "the re-check never started"; kill "$cpid" 2>/dev/null; return 1; }
    rpid="$(<"$SANDBOX/spy.pid")"
    proc_alive "$rpid" || fail "sanity: the re-check is not running before the signal"
    pkill -INT -f "$LC_DATA/hooks/secret-scan"
    wait "$cpid"
    sleep "$SETTLE_SECONDS"
    proc_alive "$rpid" && fail "the re-check process survived Ctrl-C"
    assert_eq "$(find "$TEST_WORK_BASE" -maxdepth 1 -name 'git-secret-guard.*' | wc -l | tr -d ' ')" 0 "the hook's work dir is gone"
    kill -KILL "$rpid" 2>/dev/null
    return 0
}

test_a_relative_state_home_is_one_failed_recheck_line() {
    rem_begin_with_b_open || return 1
    set_env XDG_STATE_HOME=relative/state
    rem_commit a
    assert_rc 0 "the commit passes"
    assert_last_line_is_recheck_failure "relative state home"
    assert_eq "$(doctor_starts)" 0 "no process was started with an unusable record path"
}

# ^ invariant formatting only; the reminder is built from the stdout of doctor --recheck, machine problems first, each repository's after
test_the_reminder_lists_machine_and_repository_problems_in_the_order_doctor_printed_them() {
    printf 'machine:\n  PROBLEM  hook: hook command is missing\nrepos with findings:\n  /r/b\n    PROBLEM  off in config\n  /r/c\n    PROBLEM  first\n    PROBLEM  second\n' >"$SANDBOX/recheck.out"
    fake_record
    run_report_reminder "$SANDBOX/recheck.out" "$SANDBOX/rec"
    assert_rc 0 "formatted"
    assert_empty "$OUT" "stdout stays empty"
    assert_eq "$ERR" "git-secret-guard: 4 coverage problems still open (doctor run 2026-03-04):
  machine: hook: hook command is missing
  /r/b: off in config
  /r/c: first
  /r/c: second
$REMINDER_HINT" "the whole reminder"
}

test_the_reminder_refuses_output_it_cannot_read_as_problems() {
    fake_record
    printf 'something else entirely\n' >"$SANDBOX/recheck.out"
    run_report_reminder "$SANDBOX/recheck.out" "$SANDBOX/rec"
    assert_rc 1 "nothing readable"
    assert_empty "$ERR" "nothing printed by the formatter itself"
    printf 'machine:\n  PROBLEM  x\n' >"$SANDBOX/recheck.out"
    printf 'garbage\n' >"$SANDBOX/rec"
    run_report_reminder "$SANDBOX/recheck.out" "$SANDBOX/rec"
    assert_rc 1 "no run time in the record"
}

# ^ invariant $1 = a path, $2 = expected status of report_reminder_due on it, $3 = label
assert_due_at() {
    local rc=0
    env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/common.sh" && source "$1/lib/report.sh" && report_reminder_due "$2"' _ "$GSG_PROJECT" "$1" || rc=$?
    assert_eq "$rc" "$2" "$3"
}

# ^ invariant $1 = file content (printf %b), $2 and $3 as for assert_due_at
assert_due() {
    printf '%b' "$1" >"$SANDBOX/rec"
    assert_due_at "$SANDBOX/rec" "$2" "$3"
}

test_only_a_record_with_findings_or_a_damaged_one_is_due_for_a_recheck() {
    local head='git-secret-guard findings 1\ntime 2026-03-04T05:06:07Z\n'
    assert_due_at "$SANDBOX/absent" 1 "no file"
    assert_due '' 1 "empty file"
    assert_due "$head" 1 "header only"
    assert_due "${head}machine\tx\n" 0 "a finding line"
    assert_due 'git-secret-guard findings 1\n' 0 "magic only is damaged"
    assert_due 'git-secret-guard findings 1\nPROBLEM x\n' 0 "magic and a line that is no time line is damaged"
    assert_due 'other\ntime 2026-03-04T05:06:07Z\n' 0 "wrong magic is damaged"
    assert_due "${head}\n" 0 "a blank third line is not a clean header"
}

test_control_characters_in_recheck_output_never_reach_the_reminder() {
    printf 'repos with findings:\n  /r/b\n    PROBLEM  bad \033[31mred\033[0m text\n' >"$SANDBOX/recheck.out"
    fake_record
    run_report_reminder "$SANDBOX/recheck.out" "$SANDBOX/rec"
    assert_not_contains "$ERR" $'\033' "no escape character"
    assert_contains "$ERR" "/r/b: bad ?[31mred?[0m text" "mapped to ?"
}

# ^ coupled lib/state.sh:paths_init takes the state dir from state_dir_path => the hook and doctor read one record
test_the_state_dir_has_one_definition_shared_by_the_hook_and_doctor() {
    local got
    got="$(env -i PATH="$TEST_BASE_PATH" HOME=/h XDG_STATE_HOME=/x bash -c 'source "$1/lib/common.sh" && state_dir_path' _ "$GSG_PROJECT")"
    assert_eq "$got" "/x/git-secret-guard" "XDG_STATE_HOME wins"
    got="$(env -i PATH="$TEST_BASE_PATH" HOME=/h bash -c 'source "$1/lib/common.sh" && state_dir_path' _ "$GSG_PROJECT")"
    assert_eq "$got" "/h/.local/state/git-secret-guard" "default under HOME"
    env -i PATH="$TEST_BASE_PATH" bash -c 'source "$1/lib/common.sh" && state_dir_path' _ "$GSG_PROJECT" >/dev/null 2>&1
    assert_eq "$?" 1 "neither HOME nor XDG_STATE_HOME: refused"
    grep -q 'state_dir_path' "$GSG_PROJECT/lib/state.sh" || fail "paths_init does not use state_dir_path"
}

test_the_docs_show_the_reminder_and_doctor_md_links_to_it() {
    local f
    for f in README.md docs/scan.md; do
        assert_contains "$(<"$GSG_PROJECT/$f")" "coverage problem" "$f shows the reminder"
        assert_contains "$(<"$GSG_PROJECT/$f")" "still open" "$f shows the wording"
    done
    assert_contains "$(<"$GSG_PROJECT/docs/doctor.md")" "scan.md#the-coverage-reminder" "doctor.md links to the reminder"
    assert_contains "$(<"$GSG_PROJECT/docs/scan.md")" "## The coverage reminder" "scan.md has the section"
}

run_file_tests
