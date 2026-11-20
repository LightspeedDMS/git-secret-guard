#!/usr/bin/env bash
# ^ invariant a scanner whose exit status said findings, or whose own errors file is not empty, must reach the report or the commit blocks (#31)
# ^ why report_results alone with shell functions standing in for cat and sort, not a real scanner; the check must hold whatever lost the data
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

WORK=""
LOST_TF="trufflehog reported findings but none reached the report; nothing was decided"
LOST_BL="betterleaks reported findings but none reached the report; nothing was decided"

begin() {
    new_repo "$1" || return 1
    WORK="$SANDBOX/work-$1"
    mkdir -p -- "$WORK" || return 1
    : >"$WORK/trufflehog.rows" && : >"$WORK/betterleaks.rows" && : >"$WORK/trufflehog.errors" && : >"$WORK/betterleaks.errors" || return 1
}

# ^ invariant report_with STAND_IN [MODE] runs report_results on the work dir; STAND_IN is shell text run first, it can use $W (the work dir)
report_with() {
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/core/common.sh" && source "$1/lib/scan/report.sh" || exit 9
        W="$2"
        eval "$3"
        report_results "$2" "$4"' _ "$SHARE" "$WORK" "$1" "${2:-}"
}

test_a_clean_run_with_no_marker_and_no_errors_still_passes() {
    begin clean || return 1
    report_with ""
    assert_rc 0 "passes"
    assert_empty "$ERR" "prints nothing"
}

test_a_found_marker_with_empty_rows_blocks_naming_the_scanner() {
    begin tfmarker || return 1
    : >"$WORK/trufflehog.found"
    report_with ""
    assert_rc 1 "blocked"
    assert_contains "$ERR" "$LOST_TF" "names trufflehog"
    assert_not_contains "$ERR" "betterleaks reported" "betterleaks is not blamed"
}

test_a_betterleaks_marker_with_only_a_trufflehog_row_blocks_naming_betterleaks() {
    begin blmarker || return 1
    : >"$WORK/betterleaks.found"
    printf 'trufflehog\tGithub\tmatch\tc.txt\t2\n' >"$WORK/trufflehog.rows"
    report_with ""
    assert_rc 1 "blocked"
    assert_contains "$ERR" "$LOST_BL" "names betterleaks"
    assert_not_contains "$ERR" "$LOST_TF" "trufflehog's row arrived"
    assert_contains "$ERR" "1 potential secret(s)" "the row that did arrive is still reported"
}

test_a_marker_with_its_row_present_reports_the_finding_without_the_lost_line() {
    begin both || return 1
    : >"$WORK/betterleaks.found"
    : >"$WORK/trufflehog.found"
    printf 'trufflehog\tGithub\tmatch\tc.txt\t2\n' >"$WORK/trufflehog.rows"
    printf 'betterleaks\tgithub-pat\tmatch\tc.txt\t2\n' >"$WORK/betterleaks.rows"
    report_with ""
    assert_rc 1 "blocked by the findings"
    assert_contains "$ERR" "2 potential secret(s)" "both rows reported"
    assert_not_contains "$ERR" "none reached the report" "no cross-check line"
}

test_a_no_op_cat_loses_the_rows_and_the_marker_blocks() {
    begin nocat || return 1
    : >"$WORK/trufflehog.found"
    printf 'trufflehog\tGithub\tmatch\tc.txt\t2\n' >"$WORK/trufflehog.rows"
    report_with 'cat() { return 0; }'
    assert_rc 1 "blocked"
    assert_contains "$ERR" "$LOST_TF" "the cross-check caught it"
    assert_not_contains "$ERR" "potential secret(s)" "the lost row is not reported (no tool could read it)"
}

test_a_no_op_sort_loses_the_rows_and_the_marker_blocks() {
    begin nosort || return 1
    : >"$WORK/betterleaks.found"
    printf 'betterleaks\tgithub-pat\tmatch\tc.txt\t2\n' >"$WORK/betterleaks.rows"
    report_with 'sort() { return 0; }'
    assert_rc 1 "blocked"
    assert_contains "$ERR" "$LOST_BL" "the cross-check caught it"
}

test_a_no_op_cat_loses_the_errors_and_the_scanners_own_errors_file_blocks() {
    begin nocaterr || return 1
    printf 'trufflehog: scan failed (exit 9)\n' >"$WORK/trufflehog.errors"
    report_with 'cat() { return 0; }'
    assert_rc 1 "blocked, not passed"
    assert_contains "$ERR" "trufflehog recorded errors but none reached the report; nothing was decided" "names the scanner"
    assert_not_contains "$ERR" "a scanner did not complete" "the lost errors are not shown"
}

test_errors_that_arrive_do_not_add_the_cross_check_line() {
    begin errok || return 1
    printf 'betterleaks: scan failed (exit 9)\n' >"$WORK/betterleaks.errors"
    report_with ""
    assert_rc 1 "blocked"
    assert_contains "$ERR" "betterleaks: scan failed (exit 9)" "the error is shown"
    assert_not_contains "$ERR" "none reached the report" "no cross-check line"
}

test_the_commit_message_report_gets_the_same_check() {
    begin msg || return 1
    : >"$WORK/trufflehog.found"
    report_with "" message
    assert_rc 1 "blocked"
    assert_contains "$ERR" "$LOST_TF" "the message run is checked too"
}

test_a_marker_with_an_unreadable_rows_file_blocks() {
    begin unreadable || return 1
    : >"$WORK/trufflehog.found"
    # shellcheck disable=SC2016
    report_with 'sort() { rm -f -- "$W/all.rows"; return 0; }'
    assert_rc 1 "blocked"
}

run_file_tests
