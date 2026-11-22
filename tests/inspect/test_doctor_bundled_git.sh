#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/product_call.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/product_call.sh"

# ^ coupled the doctor line for the git GitHub Desktop bundles; a bare prelude, runs on Git for Windows too

test_doctor_lists_the_bundled_git_as_a_warning_with_the_same_wording() {
    pc_bundled_git 2.45.3 || return 1
    pc_old_git_dir || return 1
    pc_run_as_root "$PC_OLD_ON_PATH"'doctor_machine_line() { printf "%s|%s\n" "$1" "$2"; }; doctor_check_git' "$SANDBOX/oldgit"
    assert_contains "$OUT" "WARNING|git: $SANDBOX/root/usr/lib/github-desktop/resources/app/git/bin/git is git 2.45.3" "doctor names it"
    assert_contains "$OUT" "commits made with it are not scanned (measured with 2.45.3)" "and says, as measured, its commits are not scanned"
    assert_not_contains "$OUT" "has not been tested" "the warning no longer says the question is open"
    assert_contains "$OUT" "oldgit/git is git 2.52.0; it ignores config-based hooks" "the second old git still gets the plain warning"
}

run_file_tests
