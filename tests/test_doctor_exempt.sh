#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

IGNORE_HINT="every commit in this repository is blocked until it is fixed (repair it with git commit --no-verify)"

test_ignore_lines_without_a_reason_are_problems_with_their_line_numbers() {
    local marker
    dr_begin && dr_repo noreason || return 1
    marker="$(new_marker)"
    cd -- "$DR_ROOTS/noreason" || return 1
    commit_ignore_file '# comment' "vendor/**   # $marker third party" 'build' '' 'dist/**' || return 1
    doctor
    assert_rc 1 "lines without a reason"
    assert_contains "$OUT" "  $DR_REAL/noreason
    PROBLEM  .secret-scan-ignore line 3: a reason is required, written as \"pattern  # why it is safe to skip\"
    PROBLEM  .secret-scan-ignore line 5: a reason is required, written as \"pattern  # why it is safe to skip\"
    PROBLEM  .secret-scan-ignore at HEAD is invalid; $IGNORE_HINT" "both lines and the consequence"
    assert_not_contains "$OUT" "line 2" "the line with a reason is fine"
    no_leak "$marker"
}

test_at_most_twenty_notes_of_one_file_are_shown() {
    local i
    local -a lines=()
    dr_begin && dr_repo many || return 1
    cd -- "$DR_ROOTS/many" || return 1
    for i in $(seq 1 25); do lines+=("pattern$i"); done
    commit_ignore_file "${lines[@]}" || return 1
    doctor
    assert_rc 1 "25 lines without a reason"
    assert_eq "$(grep -c 'a reason is required' <<<"$OUT")" 20 "twenty of them are listed"
    assert_contains "$OUT" "    PROBLEM  more problems follow; fix these first and run doctor again" "and the rest is announced"
    assert_contains "$OUT" "PROBLEM  .secret-scan-ignore at HEAD is invalid; $IGNORE_HINT" "followed by the verdict"
}

test_a_catch_all_is_a_warning_that_quotes_the_pattern_and_keeps_the_exit_status() {
    local long
    dr_begin && dr_repo wide || return 1
    cd -- "$DR_ROOTS/wide" || return 1
    long="$(printf './%.0s' $(seq 1 40))**"
    commit_ignore_file '**   # everything' "$long   # padded" 'src/*   # top level only' || return 1
    doctor
    assert_rc 0 "warnings alone do not change the exit status"
    assert_contains "$OUT" "    WARNING  .secret-scan-ignore line 1 (pattern '**') exempts the whole repository from scanning" "the plain catch-all"
    assert_contains "$OUT" "    WARNING  .secret-scan-ignore line 2 (pattern '${long:0:60}…') exempts the whole repository from scanning" "quoted as written, cut at 60 characters and marked as cut"
    assert_not_contains "$OUT" "${long:0:61}" "not one character more"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "the hook still runs there"
    assert_contains "$OUT" "warnings: " "and the summary counts the warnings"
}

test_patterns_that_only_together_cover_every_tracked_file_are_warned_about() {
    dr_begin && dr_repo union || return 1
    cd -- "$DR_ROOTS/union" || return 1
    mkdir -p src lib && printf 'a\n' >src/a.txt && printf 'b\n' >lib/b.txt && gitx add src lib || return 1
    commit_ignore_file 'src/**   # first half' 'lib/**   # second half' || return 1
    doctor
    assert_rc 0 "a warning"
    assert_contains "$OUT" "WARNING  the patterns in .secret-scan-ignore together exempt every tracked file; only .secret-scan-ignore itself is scanned" "the union warning"
}

test_only_the_committed_file_counts_never_the_index_or_the_work_tree() {
    dr_begin && dr_repo staged || return 1
    cd -- "$DR_ROOTS/staged" || return 1
    stage_file .secret-scan-ignore 'no-reason-staged' || return 1
    printf 'no-reason-worktree\n' >.secret-scan-ignore || return 1
    doctor
    assert_rc 0 "an uncommitted bad file"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "is not what the hook reads either"
}

test_a_replace_ref_cannot_hide_the_ignore_file_that_is_really_at_head() {
    dr_begin && dr_repo replaced || return 1
    cd -- "$DR_ROOTS/replaced" || return 1
    commit_ignore_file 'bad-without-reason' || return 1
    replace_head_with_permissive_commit .secret-scan-ignore 'src/**   # fine' || return 1
    doctor
    assert_rc 1 "the real HEAD holds the bad file"
    assert_contains "$OUT" "PROBLEM  .secret-scan-ignore line 1: a reason is required" "read through the replace ref"
}

test_an_ignore_file_that_is_not_a_regular_file_at_head_is_a_problem() {
    dr_begin && dr_repo linked || return 1
    cd -- "$DR_ROOTS/linked" || return 1
    ln -s /etc/passwd .secret-scan-ignore && gitx add .secret-scan-ignore && gitx commit -q --no-verify -m link || return 1
    doctor
    assert_rc 1 "a symlink at HEAD"
    assert_contains "$OUT" "PROBLEM  .secret-scan-ignore at HEAD must be a regular file (a symlink or directory is refused); every commit in this repository is blocked" "refused like the hook does"
    assert_not_contains "$OUT" "root:" "the link target is never read"
}

test_a_repo_without_commits_has_no_exemption_to_check() {
    dr_begin || return 1
    mkdir -p -- "$DR_ROOTS/fresh" && gitx init -q "$DR_ROOTS/fresh" || return 1
    doctor
    assert_rc 0 "no HEAD"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "nothing to judge"
}

test_a_pattern_with_a_control_character_is_a_problem_without_echoing_it() {
    dr_begin && dr_repo ctl || return 1
    cd -- "$DR_ROOTS/ctl" || return 1
    commit_ignore_file $'bad\e[31m   # reason' || return 1
    doctor
    assert_rc 1 "a control character"
    assert_contains "$OUT" "PROBLEM  .secret-scan-ignore line 1: the pattern is empty or holds a control character" "the hook's own wording"
    assert_not_contains "$OUT" $'\e' "and the byte never reaches the output"
}

run_file_tests
