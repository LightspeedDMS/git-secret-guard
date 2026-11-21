#!/usr/bin/env bash
# ^ invariant a scanner wrapper leaving no errors file produced no result; collect prints a line for it and report_results blocks, no pass line is printed
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/scan/report_helpers.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/report_helpers.sh"

NO_RESULT="the scanner wrapper produced no result; failing closed"

test_a_missing_errors_file_blocks_and_names_the_scanner() {
    begin one || return 1
    rm -f -- "${WORK:?}/betterleaks.errors"
    report_with ""
    assert_rc 1 "blocked"
    assert_contains "$ERR" "betterleaks: $NO_RESULT" "names betterleaks"
    assert_not_contains "$ERR" "trufflehog: $NO_RESULT" "trufflehog left its file, it is not blamed"
    assert_not_contains "$ERR" "no findings" "no pass line"
    rm -f -- "${WORK:?}/trufflehog.errors" "${WORK:?}/betterleaks.errors"
    report_with ""
    assert_rc 1 "blocked with both missing"
    assert_contains "$ERR" "trufflehog: $NO_RESULT" "names trufflehog"
    assert_contains "$ERR" "betterleaks: $NO_RESULT" "and betterleaks"
}

test_collect_prints_the_no_result_line_only_for_errors_and_never_for_rows() {
    begin collect || return 1
    rm -f -- "${WORK:?}/trufflehog.errors" "${WORK:?}/trufflehog.rows"
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/core/common.sh" && source "$1/lib/scan/report.sh" || exit 9
        collect "$2" errors; echo "rc=$?"; collect "$2" rows; echo "rc=$?"' _ "$SHARE" "$WORK"
    assert_eq "$OUT" "trufflehog: $NO_RESULT
rc=0
rc=0" "errors: one line for the missing file; rows: nothing"
}

run_file_tests
