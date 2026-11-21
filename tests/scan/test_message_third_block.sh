#!/usr/bin/env bash
# ^ see doc:docs/scan.md#the-commit-message; text below a cut line is hidden only when it is exactly git's own diff, a third part is never git's
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/scan/message_helpers.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/message_helpers.sh"

test_a_comment_block_after_the_second_part_makes_the_whole_message_scanned() {
    local control third
    begin third || return 1
    verbose_repo || return 1
    # ^ why a control run first, not the third block alone; git's diff is hidden without the block, the block is the only difference
    gitx diff --cached | verbose_message "$SANDBOX/msg-control"
    run_message_hook control "$SANDBOX/msg-control"
    assert_rc 0 "control clean"
    control="$(<"$SANDBOX/record-control.trufflehog")" || return 1
    assert_contains "$control" "subject" "control: the scan file was recorded and holds the message"
    assert_not_contains "$control" "gone $MARKER" "control: git's own diff is hidden"
    {
        gitx diff --cached
        printf '; hand added comment\nsecond part %s\n; a third comment block\n; more of it\n' "$MARKER"
    } | verbose_message "$SANDBOX/msg-third"
    run_message_hook third "$SANDBOX/msg-third"
    assert_rc 0 "clean"
    third="$(<"$SANDBOX/record-third.trufflehog")" || return 1
    assert_contains "$third" "gone $MARKER" "the removed line of the diff is scanned, nothing is hidden"
    assert_contains "$third" "diff --git" "the diff header is scanned too"
    assert_contains "$third" "second part $MARKER" "the text of the second part is scanned"
    assert_contains "$third" "; more of it" "and the third block"
}

run_file_tests
