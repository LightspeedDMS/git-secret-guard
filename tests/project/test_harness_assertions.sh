#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ coupled tests/support/lib.sh:detail_text, the one cut every failure message of an assertion goes through
# ^ why 2100, not a tighter cap; the default head (300) and tail (1500) plus the marker and the label of the message stay under it
MAX_MESSAGE_CHARS=2100

# ^ invariant failure_of CMD... runs the assertion in a subshell with its own SANDBOX and prints what fail wrote; the test's own .fails stays empty
failure_of() {
    (
        : "${SANDBOX:?}"
        SANDBOX="$SANDBOX/assert-probe"
        rm -rf -- "${SANDBOX:?}" && mkdir -p -- "$SANDBOX" || exit 1
        "$@" || true
        cat -- "$SANDBOX/.fails"
    )
}

test_assert_rc_shows_a_short_stderr_whole() {
    local msg
    RC=3 ERR="one notice line
the real error"
    msg="$(failure_of assert_rc 0 "install")"
    assert_contains "$msg" "install: expected exit 0 got 3" "the label and codes"
    assert_contains "$msg" "$ERR" "the whole stderr"
    assert_not_contains "$msg" "chars cut" "nothing is cut"
}

test_assert_rc_keeps_the_head_and_the_tail_of_a_long_stderr() {
    local msg filler
    printf -v filler '%*s' 5000 ''
    RC=1 ERR="HEADMARK ${filler// /x} TAILMARK"
    msg="$(failure_of assert_rc 0 "install")"
    assert_contains "$msg" "HEADMARK" "the head"
    assert_contains "$msg" "TAILMARK" "the tail, where the real error is"
    [[ $msg =~ \[\.\.\.\ [0-9]+\ chars\ cut\ \.\.\.\] ]] || fail "no cut marker with its size in [${msg:0:200}]"
    [ "${#msg}" -lt "$MAX_MESSAGE_CHARS" ] || fail "the message is not bounded: ${#msg} chars"
}

test_the_knobs_set_the_head_and_the_tail() {
    local msg head=10 tail=5
    RC=1 ERR="AAAAAAAAAAbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbZZZZZ"
    msg="$(GSG_TEST_DETAIL=$head GSG_TEST_DETAIL_TAIL=$tail failure_of assert_rc 0 x)"
    assert_contains "$msg" "${ERR:0:head}[... $((${#ERR} - head - tail)) chars cut ...]${ERR: -tail}" "head 10, tail 5"
}

test_assert_empty_uses_the_same_cut() {
    local msg filler
    printf -v filler '%*s' 3000 ''
    msg="$(failure_of assert_empty "HEADMARK${filler// /y}TAILMARK" "out")"
    assert_contains "$msg" "HEADMARK" "the head"
    assert_contains "$msg" "TAILMARK" "the tail"
}

run_file_tests
