#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

ESC=$'\e'
OK_ICON="${ESC}[32m✓${ESC}[0m"
PROBLEM_ICON="${ESC}[31m✗${ESC}[0m"

# ^ invariant a clean repository with one staged file; STUB_MARKER is the value the fixtures must never print
begin() {
    new_repo "$1" || return 1
    set_env STUB_MARKER="$(new_marker)"
    stage_file src/app.txt one two three
}

test_a_clean_commit_in_terminal_mode_prints_the_pass_line_with_the_ok_icon_and_nothing_else() {
    begin pass || return 1
    ui_force_terminal
    commit_cap "clean"
    assert_rc 0 commit
    assert_empty "$OUT" "stdout stays empty"
    assert_eq "$(wc -l <<<"$ERR" | tr -d ' ')" 1 "exactly one line, the commit-msg run adds none"
    assert_eq "${ERR:0:${#OK_ICON}}" "$OK_ICON" "the line starts with the ok icon"
    assert_pass_line_only "${ERR:$((${#OK_ICON} + 1))}" "the rest is the pass line, after one space"
}

test_a_blocked_commit_in_terminal_mode_puts_the_problem_icon_on_the_findings_heading_only() {
    begin block || return 1
    set_env STUB_TF_FINDINGS="AWS|true|src/app.txt|2"
    ui_force_terminal
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "${PROBLEM_ICON} git-secret-guard: 1 potential secret(s) in lines this commit adds:" "icon on the heading"
    assert_contains "$ERR" $'\n  trufflehog  AWS (match)  src/app.txt:2\n' "the finding row is as before, labelled match whatever the scanner verified"
    assert_contains "$ERR" $'\nTo bypass this check for one commit: git commit --no-verify' "the bypass hint has no icon"
    assert_eq "$(grep -c "$ESC" <<<"$ERR")" 1 "one line carries an escape sequence"
}

test_the_hook_stays_plain_with_no_color_even_when_a_terminal_is_forced() {
    begin nocolor || return 1
    ui_force_terminal
    set_env NO_COLOR=1
    commit_cap "clean"
    assert_rc 0 commit
    assert_pass_line_only "$ERR" "byte-identical plain pass line"
}

run_file_tests
