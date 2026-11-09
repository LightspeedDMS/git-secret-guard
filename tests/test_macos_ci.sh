#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$GSG_PROJECT/.github/scripts/check-macos-tests.sh"
LIST="$GSG_PROJECT/tests/macos-only.list"

# ^ invariant mk_list FILE ID... writes a list with a comment line, a blank line and the ids
mk_list() {
    local f="$1"
    shift
    printf '# a comment\n\n' >"$f"
    printf '%s\n' "$@" >>"$f"
}

check() { run_cap bash "$CHECK" "$1" "$2"; }

test_the_checker_passes_when_every_listed_test_shows_as_pass() {
    mk_list "$SANDBOX/list" a::test_one a::test_two
    printf 'PASS    a::test_one\nPASS    a::test_two (1.2s)\nSUMMARY: 2 passed\n' >"$SANDBOX/log"
    check "$SANDBOX/list" "$SANDBOX/log"
    assert_rc 0 "all listed tests passed"
    assert_contains "$OUT" "2 of 2" "the count is printed"
}

test_the_checker_fails_and_names_a_listed_test_that_was_skipped() {
    mk_list "$SANDBOX/list" a::test_one a::test_two
    printf 'PASS    a::test_one\nSKIPPED a::test_two (the BSD tools exist on macOS only)\n' >"$SANDBOX/log"
    check "$SANDBOX/list" "$SANDBOX/log"
    assert_rc 1 "a skipped test"
    assert_contains "$OUT$ERR" "a::test_two" "the skipped test is named"
    assert_contains "$OUT$ERR" "SKIPPED" "the verdict is named"
}

test_the_checker_fails_and_names_a_listed_test_that_failed() {
    mk_list "$SANDBOX/list" a::test_one
    printf 'FAIL    a::test_one (test status 1)\n' >"$SANDBOX/log"
    check "$SANDBOX/list" "$SANDBOX/log"
    assert_rc 1 "a failed test"
    assert_contains "$OUT$ERR" "a::test_one" "the failed test is named"
}

test_the_checker_fails_for_a_listed_name_that_is_not_in_the_log_at_all() {
    mk_list "$SANDBOX/list" a::test_one a::test_renamed
    printf 'PASS    a::test_one\n' >"$SANDBOX/log"
    check "$SANDBOX/list" "$SANDBOX/log"
    assert_rc 1 "a name missing from the log"
    assert_contains "$OUT$ERR" "a::test_renamed" "the missing name is named"
    assert_contains "$OUT$ERR" "not in the log" "the reason is named"
}

# ^ invariant a rename leaves the old name gone and a longer new name passing => the old name must read as missing, never as passed
test_the_checker_does_not_take_a_longer_test_name_for_the_listed_one() {
    mk_list "$SANDBOX/list" a::test_one
    printf 'PASS    a::test_one_more\n' >"$SANDBOX/log"
    check "$SANDBOX/list" "$SANDBOX/log"
    assert_rc 1 "a longer name is not the listed name"
    assert_contains "$OUT" "MISSING a::test_one (not in the log)" "the listed name is reported missing"
}

test_the_checker_judges_a_last_list_line_that_has_no_newline() {
    printf 'a::test_one\na::test_two' >"$SANDBOX/list"
    printf 'PASS    a::test_one\nSKIPPED a::test_two (reason)\n' >"$SANDBOX/log"
    check "$SANDBOX/list" "$SANDBOX/log"
    assert_rc 1 "the unterminated last line is read"
    assert_contains "$OUT" "a::test_two" "and named"
    assert_contains "$OUT" "1 of 2" "counted"
}

test_the_checker_refuses_an_empty_list_a_missing_list_and_a_missing_log() {
    printf '# only a comment\n\n' >"$SANDBOX/empty"
    printf 'PASS    a::test_one\n' >"$SANDBOX/log"
    check "$SANDBOX/empty" "$SANDBOX/log"
    assert_rc 2 "an empty list proves nothing"
    check "$SANDBOX/nolist" "$SANDBOX/log"
    assert_rc 2 "a missing list"
    mk_list "$SANDBOX/list" a::test_one
    check "$SANDBOX/list" "$SANDBOX/nolog"
    assert_rc 2 "a missing log"
    run_cap bash "$CHECK"
    assert_rc 2 "no arguments"
}

test_the_list_names_only_tests_that_exist_in_their_files() {
    local id file fn n=0
    while IFS= read -r id; do
        case "$id" in '' | '#'*) continue ;; esac
        file="${id%%::*}"
        fn="${id#*::}"
        [ -f "$GSG_PROJECT/tests/$file.sh" ] || { fail "no tests/$file.sh for $id"; continue; }
        if ! grep -q -E "^$fn\(\)" "$GSG_PROJECT/tests/$file.sh"; then fail "tests/$file.sh defines no function $fn"; fi
        n=$((n + 1))
    done <"$LIST"
    [ "$n" -ge 28 ] || fail "only $n ids in the list"
}

test_the_list_has_no_duplicates() {
    local dups
    dups="$(grep -v -E '^(#|$)' "$LIST" | sort | uniq -d)"
    assert_empty "$dups" "duplicate ids"
}

UNLISTED="$GSG_PROJECT/.github/scripts/check-macos-unlisted.sh"

unlisted() { run_cap bash "$UNLISTED" "$1" "$2" "$3"; }

test_the_unlisted_check_passes_when_every_mac_only_test_is_listed() {
    mk_list "$SANDBOX/list" a::test_one
    printf 'PASS    a::test_one\nPASS    a::test_plain\n' >"$SANDBOX/mac"
    printf 'SKIPPED a::test_one (the BSD tools exist on macOS only)\nPASS    a::test_plain\n' >"$SANDBOX/linux"
    unlisted "$SANDBOX/list" "$SANDBOX/mac" "$SANDBOX/linux"
    assert_rc 0 "the one Mac-only test is listed"
    assert_contains "$OUT" "0 unlisted" "the count is printed"
}

test_the_unlisted_check_names_a_mac_only_test_that_is_missing_from_the_list() {
    mk_list "$SANDBOX/list" a::test_one
    printf 'PASS    a::test_one\nPASS    a::test_new\n' >"$SANDBOX/mac"
    printf 'SKIPPED a::test_one (plutil is not available)\nSKIPPED a::test_new (GNUBIN_DIR exists on macOS only)\n' >"$SANDBOX/linux"
    unlisted "$SANDBOX/list" "$SANDBOX/mac" "$SANDBOX/linux"
    assert_rc 1 "an unlisted Mac-only test"
    assert_contains "$OUT" "UNLISTED a::test_new (GNUBIN_DIR exists on macOS only)" "named with its reason"
    assert_not_contains "$OUT" "UNLISTED a::test_one" "the listed one is not named"
    assert_contains "$OUT" "1 unlisted" "counted"
}

test_the_unlisted_check_ignores_skips_that_are_not_about_macos_or_that_skip_on_the_mac_too() {
    : >"$SANDBOX/list"
    printf '# none\nb::test_never\n' >"$SANDBOX/list"
    printf 'PASS    a::test_scanner\nSKIPPED a::test_systemd (no unit)\nPASS    a::test_both_skip_wrongly\n' >"$SANDBOX/mac"
    printf 'SKIPPED a::test_scanner (GSG_TEST_SERVICE_UNIT is not set)\nSKIPPED a::test_systemd (systemctl is not available)\nSKIPPED a::test_gone (macOS only)\n' >"$SANDBOX/linux"
    unlisted "$SANDBOX/list" "$SANDBOX/mac" "$SANDBOX/linux"
    assert_rc 0 "a Linux-only skip reason, and a test that did not pass on the Mac, are not this check's business"
}

test_the_unlisted_check_does_not_take_a_longer_name_for_a_listed_one() {
    mk_list "$SANDBOX/list" a::test_one
    printf 'PASS    a::test_one_more\n' >"$SANDBOX/mac"
    printf 'SKIPPED a::test_one_more (macOS only)\n' >"$SANDBOX/linux"
    unlisted "$SANDBOX/list" "$SANDBOX/mac" "$SANDBOX/linux"
    assert_rc 1 "the longer name is a different test"
    assert_contains "$OUT" "UNLISTED a::test_one_more" "named"
}

test_the_unlisted_check_refuses_bad_input() {
    mk_list "$SANDBOX/list" a::test_one
    printf 'PASS    a::test_one\n' >"$SANDBOX/mac"
    printf 'SKIPPED a::test_one (macOS only)\n' >"$SANDBOX/linux"
    : >"$SANDBOX/empty"
    unlisted "$SANDBOX/list" "$SANDBOX/empty" "$SANDBOX/linux"
    assert_rc 2 "an empty Mac log proves nothing"
    unlisted "$SANDBOX/list" "$SANDBOX/mac" "$SANDBOX/empty"
    assert_rc 2 "an empty Linux log proves nothing"
    unlisted "$SANDBOX/list" "$SANDBOX/mac" "$SANDBOX/none"
    assert_rc 2 "a missing log"
    run_cap bash "$UNLISTED" "$SANDBOX/list"
    assert_rc 2 "too few arguments"
}

test_the_unlisted_check_names_an_empty_list_instead_of_reading_the_logs_in_its_place() {
    : >"$SANDBOX/list"
    printf 'PASS    a::test_one\n' >"$SANDBOX/mac"
    printf 'SKIPPED a::test_one (macOS only)\n' >"$SANDBOX/linux"
    unlisted "$SANDBOX/list" "$SANDBOX/mac" "$SANDBOX/linux"
    assert_rc 2 "an empty list"
    assert_contains "$OUT$ERR" "$SANDBOX/list is empty" "the empty file is named"
}

# ^ invariant every real Mac-only skip wording of the suite is seen by MAC_REASON => the list in the repo is judged against a Linux log of the real tests
test_the_unlisted_check_accepts_the_real_list_against_logs_built_from_it() {
    local id
    : >"$SANDBOX/mac" && : >"$SANDBOX/linux"
    while IFS= read -r id; do
        case "$id" in '' | '#'*) continue ;; esac
        printf 'PASS    %s\n' "$id" >>"$SANDBOX/mac"
        printf 'SKIPPED %s (the BSD tools exist on macOS only)\n' "$id" >>"$SANDBOX/linux"
    done <"$LIST"
    unlisted "$LIST" "$SANDBOX/mac" "$SANDBOX/linux"
    assert_rc 0 "every id of the real list is listed"
}

run_file_tests
