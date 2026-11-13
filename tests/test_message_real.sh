#!/usr/bin/env bash
# ^ see doc:docs/scan.md#the-commit-message; the real scanners read the message through the commit-msg event, as git runs it
# ^ external a dead proxy makes trufflehog's verification fail => result "unknown" (online, a fake credential is "unverified" and hidden)
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)

begin_real() {
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    use_real_tools
    enable_message_hook
    set_env "${DEAD_PROXY[@]}"
    new_repo "$1"
}
has_head() { gitx rev-parse -q --verify HEAD >/dev/null 2>&1; }
token_line() { printf 'token = "%s"' "$(fake_github_token)"; }
assert_message_blocked() {
    assert_rc 1 "$1 blocked"
    assert_contains "$ERR" "potential secret(s) in the commit message" "$1 by a finding in the message"
    assert_contains "$ERR" "commit message:$2" "$1 at its line"
    assert_not_contains "$ERR" "nothing was scanned" "$1 the scan ran"
    no_leak "$(fake_github_token)"
}

test_real_a_token_in_dash_m_blocks_the_commit_and_the_value_is_never_printed() {
    begin_real dashm || return 1
    stage_file src/app.txt "clean content"
    commit_cap "fix: rotate $(fake_github_token)"
    assert_message_blocked "-m" 1
    if has_head; then fail "a commit was created"; fi
}

test_real_a_token_in_dash_f_blocks_on_its_line() {
    begin_real dashf || return 1
    printf 'fix: rotate\n\nthe old credential was\n%s\n' "$(token_line)" >"$SANDBOX/msg-f"
    stage_file src/app.txt "clean content"
    run_cap gitx commit -q -F "$SANDBOX/msg-f"
    assert_message_blocked "-F" 4
    if has_head; then fail "a commit was created"; fi
}

# ^ invariant prints the path of a GIT_EDITOR script putting its arguments (one per line) above what git wrote into the message file
editor_that_writes() {
    local file="$SANDBOX/editor-$$.sh"
    { printf '#!/bin/sh\n{\n'; printf 'printf "%%s\\n" %q\n' "$@"; printf 'cat "$1"\n} >"$1.new" && cat "$1.new" >"$1"\n'; } >"$file" || return 1
    chmod 755 -- "$file" || return 1
    printf '%s' "$file"
}

test_real_a_token_typed_in_the_editor_blocks_and_git_own_comment_lines_do_not() {
    begin_real editor || return 1
    stage_file src/app.txt "clean content"
    set_env GIT_EDITOR="$(editor_that_writes "fix: rotate" "" "$(token_line)")"
    run_cap gitx commit -q
    assert_message_blocked "editor" 3
    if has_head; then fail "a commit was created"; fi
    set_env GIT_EDITOR="$(editor_that_writes "fix: nothing to hide")"
    run_cap gitx commit -q
    assert_rc 0 "an editor message that holds only git's own comment lines besides the subject"
    assert_not_contains "$ERR" "potential secret" "git's template comments are no finding"
}

test_real_a_token_in_an_amended_message_blocks_and_the_old_commit_stays() {
    begin_real amend || return 1
    stage_file src/app.txt "clean content"
    gitx commit -q --no-verify -m "base"
    local before
    before="$(gitx rev-parse HEAD)"
    run_cap gitx commit -q --amend -m "fix: rotate $(fake_github_token)"
    assert_message_blocked "amend" 1
    assert_eq "$(gitx rev-parse HEAD)" "$before" "HEAD is the commit it was"
}

test_real_a_token_in_a_merge_message_blocks_the_merge_commit() {
    begin_real merge || return 1
    stage_file base.txt one
    gitx commit -q --no-verify -m "base" || return 1
    gitx checkout -q -b side && stage_file side.txt two && gitx commit -q --no-verify -m "side" || return 1
    gitx checkout -q main && stage_file main.txt three && gitx commit -q --no-verify -m "main" || return 1
    local before
    before="$(gitx rev-parse HEAD)"
    run_cap gitx merge --no-ff -m "merge: $(fake_github_token)" side
    assert_message_blocked "merge" 1
    assert_eq "$(gitx rev-parse HEAD)" "$before" "no merge commit was made"
}

test_real_a_token_only_in_the_removed_lines_of_a_commit_v_diff_does_not_block() {
    begin_real verbose || return 1
    stage_file secret.env "$(token_line)"
    gitx commit -q --no-verify -m "an old leak" || return 1
    stage_file secret.env "token removed"
    set_env GIT_EDITOR="$(editor_that_writes "fix: remove the old token")"
    run_cap gitx commit -q -v
    assert_rc 0 "the removed line sits below the scissors line"
    assert_not_contains "$ERR" "potential secret" "no finding"
    assert_pass_line_only "$ERR" "only the lines run's pass line"
}

test_real_a_token_in_a_comment_line_above_the_scissors_blocks() {
    begin_real comment || return 1
    stage_file src/app.txt "clean content"
    set_env GIT_EDITOR="$(editor_that_writes "fix: a subject" "# note for me: $(fake_github_token)")"
    run_cap gitx commit -q -v
    assert_message_blocked "comment line" 2
    if has_head; then fail "a commit was created"; fi
}

test_real_a_cut_block_copied_into_a_dash_f_file_hides_nothing() {
    begin_real copied || return 1
    local sc=' ------------------------ >8 ------------------------'
    printf 'subject\n#%s\n# Do not modify or remove the line above.\ndiff --git a/x b/x\n-%s\n' "$sc" "$(token_line)" >"$SANDBOX/msg-copied"
    stage_file src/app.txt "clean content"
    run_cap gitx commit -q -F "$SANDBOX/msg-copied"
    assert_message_blocked "copied cut block" 5
    if has_head; then fail "a commit was created"; fi
}

test_real_commit_v_v_passes_a_token_only_in_the_removed_lines_of_the_staged_diff() {
    begin_real vv || return 1
    stage_file secret.env "$(token_line)" && stage_file other.env "clean"
    gitx commit -q --no-verify -m "old leak" || return 1
    stage_file secret.env "token removed"
    printf 'changed\n' >other.env
    set_env GIT_EDITOR="$(editor_that_writes "fix: remove the old token")"
    run_cap gitx commit -q -v -v
    assert_rc 0 "the removed line sits in the staged diff below the cut, which equals git diff --cached"
    assert_not_contains "$ERR" "potential secret" "no finding"
    assert_pass_line_only "$ERR" "only the lines run's pass line"
}

# ^ invariant the work tree part of -v -v is never hidden (its text is in no tree, git diff would run clean filters); a removed secret there blocks
test_real_commit_v_v_blocks_a_token_in_a_removed_line_of_the_worktree_diff_a_documented_false_block() {
    begin_real vvfalse || return 1
    stage_file other.env "$(token_line)" && stage_file s.txt "clean"
    gitx commit -q --no-verify -m "old leak" || return 1
    printf 'removed from the work tree only\n' >other.env
    stage_file s.txt "clean" "changed"
    set_env GIT_EDITOR="$(editor_that_writes "fix: subject")"
    run_cap gitx commit -q -v -v
    assert_rc 1 "the removed line of the work tree diff is scanned, so the commit is blocked"
    assert_contains "$ERR" "potential secret(s) in the commit message" "found below the cut line"
    no_leak "$(fake_github_token)"
}

test_real_a_vv_file_reused_with_dash_f_blocks_the_unstaged_token() {
    begin_real vvreuse || return 1
    local tok saved="$SANDBOX/vv-saved" ed="$SANDBOX/editor-save.sh"
    tok="$(fake_github_token)"
    stage_file w.txt "clean" && gitx commit -q --no-verify -m base || return 1
    stage_file w.txt "clean" "unstaged token = \"$tok\"" && gitx add w.txt && gitx reset -q w.txt || return 1
    stage_file s.txt "staged and clean" || return 1
    printf '#!/bin/sh\ncp "$1" %q\nprintf "subject %s\\n" >"$1"\n' "$saved" "$tok" >"$ed" && chmod 755 "$ed" || return 1
    set_env GIT_EDITOR="$ed"
    run_cap gitx commit -q -v -v
    assert_rc 1 "the subject token blocks the first attempt"
    assert_eq "$(grep -c -F -- "$tok" "$saved")" 1 "git wrote the unstaged token into the -v -v message file (worktree part)"
    { printf 'fixed subject\n'; cat -- "$saved"; } >"$SANDBOX/msg-reuse"
    run_cap gitx commit -q -F "$SANDBOX/msg-reuse"
    assert_rc 1 "the reused file is scanned, the work tree part is in no tree"
    assert_contains "$ERR" "potential secret(s) in the commit message" "found in the message"
    no_leak "$tok"
    if has_head && [ "$(gitx log -1 --format=%s)" = "fixed subject" ]; then fail "a commit with the unstaged token was made"; fi
}

test_real_a_head_parent_diff_with_an_added_token_not_in_the_staged_tree_blocks() {
    begin_real parentadd || return 1
    local sc=' ------------------------ >8 ------------------------'
    stage_file secret.env "old" && gitx commit -q --no-verify -m leak || return 1
    stage_file secret.env "clean" && gitx commit -q --no-verify -m remove || return 1
    stage_file other.txt "more content"
    { printf 'subject\n#%s\n# Do not modify or remove the line above.\n' "$sc"; gitx diff --cached HEAD^ | sed "s|^+more content|+$(token_line)|"; } >"$SANDBOX/msg-padd"
    run_cap gitx commit -q -F "$SANDBOX/msg-padd"
    assert_rc 1 "an added line the staged tree does not hold makes the text no diff of git"
    assert_contains "$ERR" "potential secret(s) in the commit message" "scanned whole"
    no_leak "$(fake_github_token)"
}

test_real_amend_v_passes_a_token_removed_since_the_parent() {
    begin_real amendv || return 1
    stage_file secret.env "$(token_line)" && gitx commit -q --no-verify -m "leak" || return 1
    stage_file secret.env "token removed" && gitx commit -q --no-verify -m "remove" || return 1
    stage_file other.txt "more content"
    set_env GIT_EDITOR="$(editor_that_writes "fix: amended")"
    run_cap gitx commit -q --amend -v
    assert_rc 0 "an amend -v diff starts at HEAD^, where the token is a removed line"
    assert_not_contains "$ERR" "potential secret" "no finding"
}

test_real_a_clean_message_adds_no_output_line_to_the_pass_line() {
    begin_real cleanmsg || return 1
    stage_file src/app.txt "hello world"
    commit_cap "fix: a clean subject" -m "and a clean body"
    assert_rc 0 commit
    assert_empty "$OUT" "stdout stays empty"
    assert_pass_line_only "$ERR" "one line, from the lines run"
}

test_real_no_verify_skips_the_message_scan_as_it_skips_the_lines_scan() {
    begin_real noverify || return 1
    stage_file src/app.txt "hello world"
    commit_cap "fix: $(fake_github_token)" --no-verify
    assert_rc 0 "--no-verify"
    assert_empty "$ERR" "no hook ran"
}

test_real_a_catch_all_exemption_at_head_does_not_exempt_the_message() {
    begin_real exempt || return 1
    stage_file .secret-scan-ignore "** # test only: every file"
    gitx commit -q --no-verify -m "exempt everything" || return 1
    stage_file src/app.txt "hello world"
    commit_cap "fix: $(fake_github_token)"
    assert_message_blocked "path exemption" 1
}

test_real_a_reword_in_an_interactive_rebase_runs_the_event() {
    begin_real reword || return 1
    local seq="$SANDBOX/seq.sh"
    stage_file a.txt one && gitx commit -q --no-verify -m "one" || return 1
    stage_file b.txt two && gitx commit -q --no-verify -m "two" || return 1
    printf '#!/bin/sh\nsed "1s/^pick/reword/" "$1" >"$1.new" && cat "$1.new" >"$1"\n' >"$seq" && chmod 755 "$seq" || return 1
    set_env GIT_SEQUENCE_EDITOR="$seq" GIT_EDITOR="$(editor_that_writes "reworded $(fake_github_token)")"
    run_cap gitx rebase -i HEAD~1
    assert_rc 1 "the reword stops the rebase"
    assert_contains "$ERR" "potential secret(s) in the commit message" "the rebase reword ran commit-msg"
    no_leak "$(fake_github_token)"
}

test_real_a_commit_after_a_squash_merge_is_scanned() {
    begin_real squash || return 1
    stage_file a.txt one && gitx commit -q --no-verify -m "one" || return 1
    gitx checkout -q -b side && stage_file s.txt two && gitx commit -q --no-verify -m "two" || return 1
    gitx checkout -q main || return 1
    gitx merge -q --squash side >/dev/null || return 1
    run_cap gitx commit -q -m "squash $(fake_github_token)"
    assert_message_blocked "squash" 1
}

# ^ external measured on git 2.56 (see docs/scan.md#the-commit-message), revert, cherry-pick and am never run commit-msg; am runs applypatch-msg instead
test_real_revert_cherry_pick_and_am_do_not_run_the_event_a_documented_limit() {
    begin_real skipped || return 1
    local tok subj
    tok="$(fake_github_token)"
    stage_file a.txt one && gitx commit -q --no-verify -m "one" || return 1
    gitx checkout -q -b side && stage_file s.txt side && gitx commit -q --no-verify -m "side" || return 1
    gitx format-patch -1 --stdout side >"$SANDBOX/p.patch" || return 1
    subj="Subject: [PATCH] am $tok"
    sed -i "s|^Subject: .*|$subj|" "$SANDBOX/p.patch" || return 1
    gitx checkout -q main && stage_file b.txt two && gitx commit -q --no-verify -m "two" || return 1
    # ^ why --edit, not a bare revert; without a terminal git revert implies --no-edit and the editor never runs
    set_env GIT_EDITOR="$(editor_that_writes "revert $tok")"
    run_cap gitx revert --edit HEAD
    assert_rc 0 "revert commits the edited message unscanned" || return 1
    assert_eq "$(gitx log -1 --format=%B | grep -c -F -- "$tok")" 1 "the token is in the message of the revert" || return 1
    set_env GIT_EDITOR="$(editor_that_writes "pick $tok")"
    run_cap gitx cherry-pick -e side
    assert_rc 0 "cherry-pick -e commits the edited message unscanned" || return 1
    assert_eq "$(gitx log -1 --format=%B | grep -c -F -- "$tok")" 1 "the token is in the message of the pick" || return 1
    gitx checkout -q -b amb HEAD~3 || return 1
    run_cap gitx am "$SANDBOX/p.patch"
    assert_rc 0 "am commits the patch message unscanned"
    assert_eq "$(gitx log -1 --format=%B | grep -c -F -- "$tok")" 1 "the token is in the message from the patch"
    assert_not_contains "$ERR" "commit message" "no message scan ran"
}

test_real_a_fixup_in_an_interactive_rebase_runs_no_event_a_documented_limit() {
    begin_real fixup || return 1
    local seq="$SANDBOX/seq-fixup.sh" tok
    tok="$(fake_github_token)"
    stage_file z.txt zero && gitx commit -q --no-verify -m "zero" || return 1
    stage_file a.txt one && gitx commit -q --no-verify -m "one" || return 1
    stage_file b.txt two && gitx commit -q --no-verify -m "two $tok" || return 1
    printf '#!/bin/sh\nsed "2s/^pick/fixup -C/" "$1" >"$1.new" && cat "$1.new" >"$1"\n' >"$seq" && chmod 755 "$seq" || return 1
    set_env GIT_SEQUENCE_EDITOR="$seq" GIT_EDITOR=true
    run_cap gitx rebase -i HEAD~2
    assert_rc 0 "the fixup keeps the message of the second commit unscanned"
    assert_eq "$(gitx log -1 --format=%B | grep -c -F -- "$tok")" 1 "the token is in the message after the rebase"
    assert_not_contains "$ERR" "potential secret" "no message scan ran"
}

test_real_a_head_gitleaksignore_applied_to_a_merge_message_is_announced() {
    begin_real mergeignore || return 1
    stage_file base.txt one && gitx commit -q --no-verify -m "base" || return 1
    gitx checkout -q -b side && stage_file side.txt two && gitx commit -q --no-verify -m "side" || return 1
    gitx checkout -q main && stage_file .gitleaksignore "COMMIT_EDITMSG:aws-access-key-id:1" && gitx commit -q --no-verify -m "ignore" || return 1
    run_cap gitx merge --no-ff -m "merge: $(fake_aws_key)" side
    assert_contains "$ERR" "using .gitleaksignore from HEAD" "a merge never runs pre-commit, so the message run says what mutes it"
    no_leak "$(fake_aws_key)"
}

run_file_tests
