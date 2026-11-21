#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/doctor.sh"
# shellcheck source=tests/inspect/findings_helpers.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/findings_helpers.sh"

# ^ hazard mv onto a directory moves the temp file into it and exits 0 => the run would report a record it never wrote
test_a_directory_at_the_record_path_is_refused_and_left_empty() {
    local rec
    dr_begin && dr_repo off || return 1
    gitx -C "$DR_ROOTS/off" config hook.git-secret-guard.enabled false || return 1
    rec="$(rec_file)"
    mkdir -p -- "$rec" || return 1
    doctor
    assert_eq "$RC" 2 "a full run with a directory where the record goes"
    assert_contains "$ERR" "cannot write the findings record, $rec is a directory" "says what and where"
    if [ ! -d "$rec" ] || [ -L "$rec" ]; then fail "the record path must stay a plain directory after the refused run"; fi
    assert_empty "$(ls -A -- "$rec")" "no temp file was moved into the directory"
    assert_empty "$(find "$LC_STATE" -mindepth 1 -maxdepth 1 -name 'findings.*')" "no temp file or lock left in the state dir"
}

# ^ why a regular file at the lock path, not chmod 500 on the state dir; state_make_dir resets the mode to 700 first
# ^ invariant ln -s fails on an existing path of no pid link and no directory => no holder to read, doctor gives up after ABSENT_MAX looks
test_a_lock_path_that_cannot_be_taken_refuses_and_keeps_the_record() {
    local lock before
    dr_begin && dr_repo off || return 1
    gitx -C "$DR_ROOTS/off" config hook.git-secret-guard.enabled false || return 1
    write_record "machine${TAB}x" || return 1
    before="$(cat -- "$(rec_file)")" || return 1
    lock="$LC_STATE/findings.lock"
    printf 'not ours\n' >"$lock" || return 1
    doctor
    assert_eq "$RC" 2 "a full run whose lock cannot be created"
    assert_contains "$ERR" "cannot create the lock $lock" "says what and where"
    assert_eq "$(cat -- "$(rec_file)")" "$before" "the old record is untouched"
    assert_eq "$(cat -- "$lock")" "not ours" "the file at the lock path is left alone"
    assert_empty "$(find "$LC_STATE" -mindepth 1 -maxdepth 1 -name 'findings.*' ! -name findings.lock)" "no temp file left in the state dir"
}

run_file_tests
