#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ why a synthetic trace and files, not a coverage run; the test checks only how coverage.awk maps a trace path to a file of the checkout, and runs in a blink

COV_FILE=lib/a.sh
# ^ invariant four code lines and a trace hitting lines 1 and 3 => every layout reads 2/4 lines (50.0 %)
COV_LINES=('a=1' 'b=2' 'c=3' 'd=4')

# ^ invariant cov_layout DIR [TRACE_PREFIX] makes a checkout at DIR holding COV_FILE and prints the path of its trace file
# ^ invariant the trace names the file by its absolute path under TRACE_PREFIX (default DIR), as bash -x does
cov_layout() {
    local dir="$1" prefix="${2:-$1}" trace="$1.trace"
    mkdir -p -- "$dir/lib" || return 1
    printf '%s\n' "${COV_LINES[@]}" >"$dir/$COV_FILE" || return 1
    printf 'TRACE %s:1:\nTRACE %s:3:\n' "$prefix/$COV_FILE" "$prefix/$COV_FILE" >"$trace" || return 1
    printf '%s' "$trace"
}

# ^ invariant cov_report DIR TRACE prints the report of coverage.awk run in DIR as tests/coverage.sh runs it, with -v root=DIR
cov_report() {
    (cd -- "$1" && awk -v trace="$2" -v root="$1" -f "$GSG_PROJECT/tests/coverage.awk" "$COV_FILE")
}

# ^ invariant cov_run DIR [TRACE_PREFIX] builds the layout, checks it, and prints the report
cov_run() {
    local trace
    trace="$(cov_layout "$@")" || return 1
    cov_report "$1" "$trace"
}

test_a_checkout_is_covered_the_same_whatever_its_directory_is_called() {
    local out_named out_other out_share
    out_named="$(cov_run "$SANDBOX/git-secret-guard")" || return 1
    out_other="$(cov_run "$SANDBOX/checkout-two")" || return 1
    out_share="$(cov_run "$SANDBOX/share/checkout-three")" || return 1
    assert_contains "$out_named" "TOTAL 2/4 50.0%" "the checkout named git-secret-guard reads 2 of 4 lines"
    assert_contains "$out_named" "$COV_FILE" "the report names the file by its path in the checkout"
    assert_eq "$out_other" "$out_named" "a checkout in a directory with another name reads the same lines"
    assert_eq "$out_share" "$out_named" "a checkout below a directory called share reads the same lines"
}

test_the_missed_lines_are_listed_for_every_layout() {
    local out
    out="$(cov_run "$SANDBOX/other-name")" || return 1
    assert_contains "$out" "    2: b=2" "the second line is listed as missed"
    assert_contains "$out" "    4: d=4" "the fourth line is listed as missed"
    assert_not_contains "$out" "    1: a=1" "a line the trace hit is not listed"
}

test_an_installed_copy_still_maps_through_its_share_directory() {
    local out
    out="$(cov_run "$SANDBOX/work" "$SANDBOX/home/.local/share")" || return 1
    assert_contains "$out" "TOTAL 2/4 50.0%" "a trace from an installed copy still lands on the checkout's file"
}

test_the_runner_names_the_checkout_root_to_the_awk() {
    local text
    text="$(<"$GSG_PROJECT/tests/coverage.sh")" || return 1
    # shellcheck disable=SC2016
    assert_contains "$text" '-v root="$PROJECT"' "coverage.sh passes the checkout root it computed"
}

run_file_tests
