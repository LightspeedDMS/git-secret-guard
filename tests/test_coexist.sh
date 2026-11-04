#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

ORDER="" HLOG=""
begin() {
    new_repo "$1" || return 1
    ORDER="$SANDBOX/order-$1"
    HLOG="$SANDBOX/hooklog-$1"
    mkdir -p -- "$HLOG"
    set_env STUB_LOG="$ORDER" STUB_MARKER="$(new_marker)"
    stage_file base.txt base
    commit_cap "base" || return 1
    [ "$RC" -eq 0 ] || fail "setup commit failed: $ERR"
    : >"$ORDER"
}

install_hook() {
    local dir="$1" name="$2" code="$3" with_stdin="${4:-}"
    {
        echo '#!/bin/sh'
        printf '%s\n' "{ printf 'args:'; for a in \"\$@\"; do printf ' [%s]' \"\$a\"; done; printf '\\n'; } >>'$HLOG/$name'"
        if [ "$with_stdin" = stdin ]; then echo "cat >>'$HLOG/$name.stdin'"; fi
        echo "echo '$name' >>'$ORDER'"
        echo "exit $code"
    } >"$dir/$name"
    chmod +x -- "$dir/$name"
}
repo_hook() { install_hook "$REPO/.git/hooks" "$@"; }
hook_args() { cat -- "$HLOG/$1" 2>/dev/null; }
line_of() { grep -n -m1 "^$1" "$ORDER" | cut -d: -f1; }

test_sandbox_never_applies_the_real_global_config() {
    new_repo iso || return 1
    assert_empty "$(gitx config --get core.hooksPath)" "no hooksPath leaks into the sandbox"
    assert_eq "$(windows_or_plain "$(gitx config --show-origin --get "hook.$HOOK_NAME.command" | cut -f1)")" "file:$SANDBOX/gitconfig" "hook config comes from the scratch file"
    assert_eq "$(gitx config --global --get user.email)" "test@example.invalid" "scratch identity"
}

test_repo_pre_commit_runs_and_runs_after_the_scan() {
    begin pc || return 1
    repo_hook pre-commit 0
    stage_file a.txt one
    commit_cap "a"
    assert_rc 0 commit
    assert_eq "$(hook_args pre-commit)" "args:" "no arguments for pre-commit"
    local scan_last repo_line
    scan_last="$(line_of betterleaks)"
    repo_line="$(line_of pre-commit)"
    [ -n "$scan_last" ] && [ -n "$repo_line" ] && [ "$repo_line" -gt "$scan_last" ] || fail "scan ($scan_last) did not come before the repo hook ($repo_line)"
    [ "$(line_of trufflehog)" -lt "$repo_line" ] || fail "trufflehog did not run before the repo hook"
}

test_failing_repo_pre_commit_still_blocks_the_commit() {
    begin pcfail || return 1
    repo_hook pre-commit 1
    stage_file a.txt one
    commit_cap "a"
    assert_rc 1 "blocked by the repo hook"
    assert_eq "$(gitx rev-list --count HEAD)" 1 "no new commit"
}

test_scan_finding_blocks_even_when_the_repo_hook_passes() {
    begin pcscan || return 1
    repo_hook pre-commit 0
    stage_file a.txt one
    set_env STUB_TF_FINDINGS="AWS|true|a.txt|1"
    commit_cap "a"
    assert_rc 1 "blocked by the scan"
    assert_contains "$ERR" "a.txt:1" "finding reported"
    assert_eq "$(gitx rev-list --count HEAD)" 1 "no new commit"
}

test_prepare_commit_msg_gets_the_message_file_and_source() {
    begin pcm || return 1
    repo_hook prepare-commit-msg 0
    stage_file a.txt one
    commit_cap "a"
    assert_rc 0 commit
    assert_contains "$(hook_args prepare-commit-msg)" "COMMIT_EDITMSG] [message]" "git's arguments"
}

test_failing_prepare_commit_msg_blocks() {
    begin pcmfail || return 1
    repo_hook prepare-commit-msg 1
    stage_file a.txt one
    commit_cap "a"
    assert_rc 1 "blocked"
    assert_eq "$(gitx rev-list --count HEAD)" 1 "no new commit"
}

test_commit_msg_gets_the_message_file() {
    begin cm || return 1
    repo_hook commit-msg 0
    stage_file a.txt one
    commit_cap "a"
    assert_rc 0 commit
    assert_contains "$(hook_args commit-msg)" "COMMIT_EDITMSG]" "git's argument"
}

test_failing_commit_msg_blocks() {
    begin cmfail || return 1
    repo_hook commit-msg 1
    stage_file a.txt one
    commit_cap "a"
    assert_rc 1 "blocked"
    assert_eq "$(gitx rev-list --count HEAD)" 1 "no new commit"
}

test_post_commit_runs_and_its_status_does_not_undo_the_commit() {
    begin postc || return 1
    repo_hook post-commit 3
    stage_file a.txt one
    commit_cap "a"
    assert_rc 0 commit
    assert_eq "$(hook_args post-commit)" "args:" "no arguments for post-commit"
    assert_eq "$(gitx rev-list --count HEAD)" 2 "commit stays"
}

test_post_checkout_gets_old_new_and_flag() {
    begin postco || return 1
    repo_hook post-checkout 0
    run_cap gitx checkout -q -b feature
    assert_rc 0 checkout
    local args
    args="$(hook_args post-checkout)"
    [[ "$args" =~ ^args:\ \[[0-9a-f]{40}\]\ \[[0-9a-f]{40}\]\ \[1\]$ ]] || fail "unexpected post-checkout args: $args"
}

test_post_merge_gets_the_squash_flag() {
    begin postm || return 1
    gitx checkout -q -b side
    stage_file side.txt side
    commit_cap "side"
    gitx checkout -q main 2>/dev/null || gitx checkout -q master
    repo_hook post-merge 0
    : >"$ORDER"
    run_cap gitx merge --no-ff -q -m "merge side" side
    assert_rc 0 merge
    assert_eq "$(hook_args post-merge)" "args: [0]" "post-merge receives the squash flag"
    assert_not_contains "$(<"$ORDER")" "trufflehog" "documented limit: a merge commit fires pre-merge-commit, not pre-commit"
}

test_pre_push_gets_remote_and_ref_lines_on_stdin_and_can_block() {
    begin prepush || return 1
    local remote="$SANDBOX/remote-prepush.git"
    gitx init -q --bare "$remote"
    gitx remote add origin "$remote"
    repo_hook pre-push 0 stdin
    run_cap gitx push -q origin HEAD:refs/heads/main
    assert_rc 0 push
    assert_eq "$(windows_or_plain "$(hook_args pre-push)")" "args: [origin] [$remote]" "remote name and url"
    assert_contains "$(<"$HLOG/pre-push.stdin")" "refs/heads/main" "ref lines on stdin"
    repo_hook pre-push 1 stdin
    stage_file more.txt more && commit_cap "more"
    run_cap gitx push -q origin HEAD:refs/heads/other
    [ "$RC" -ne 0 ] || fail "failing pre-push did not block"
    assert_eq "$(gitx --git-dir="$remote" for-each-ref --format='%(refname)' | tr '\n' ' ')" "refs/heads/main " "remote untouched by the blocked push"
}

test_reference_transaction_runs_with_stdin_and_can_abort() {
    begin reftx || return 1
    repo_hook reference-transaction 0 stdin
    stage_file a.txt one
    commit_cap "a"
    assert_rc 0 commit
    assert_contains "$(hook_args reference-transaction)" "[prepared]" "prepared state"
    assert_contains "$(hook_args reference-transaction)" "[committed]" "committed state"
    assert_contains "$(<"$HLOG/reference-transaction.stdin")" "refs/heads/" "ref updates on stdin"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\n[ "$1" = prepared ] && exit 1\nexit 0\n' >"$REPO/.git/hooks/reference-transaction"
    stage_file b.txt two
    commit_cap "b"
    [ "$RC" -ne 0 ] || fail "failing reference-transaction did not abort the commit"
    assert_eq "$(gitx rev-list --count HEAD)" 2 "no new commit"
}

make_bare_remote() {
    REMOTE="$SANDBOX/remote-$1.git"
    gitx init -q --bare "$REMOTE"
    gitx remote add origin "$REMOTE"
}

test_server_side_pre_receive_rejects_the_push() {
    begin srvpre || return 1
    make_bare_remote srvpre
    install_hook "$REMOTE/hooks" pre-receive 1 stdin
    install_hook "$REMOTE/hooks" post-receive 0 stdin
    run_cap gitx push origin HEAD:refs/heads/main
    [ "$RC" -ne 0 ] || fail "a rejecting pre-receive did not block the push"
    assert_contains "$ERR" "pre-receive hook declined" "git reports the decline"
    assert_no_file "$HLOG/post-receive" "post-receive must not run after a rejection"
    assert_contains "$(<"$HLOG/pre-receive.stdin")" "refs/heads/main" "pre-receive got the ref lines"
}

test_server_side_update_rejects_the_push() {
    begin srvupd || return 1
    make_bare_remote srvupd
    install_hook "$REMOTE/hooks" update 1
    run_cap gitx push origin HEAD:refs/heads/main
    [ "$RC" -ne 0 ] || fail "a rejecting update hook did not block the push"
    assert_contains "$ERR" "hook declined" "git reports the decline"
    assert_eq "$(gitx --git-dir="$REMOTE" for-each-ref | wc -l)" 0 "remote has no refs"
}

test_server_side_post_receive_runs_after_a_successful_push() {
    begin srvpost || return 1
    make_bare_remote srvpost
    install_hook "$REMOTE/hooks" pre-receive 0 stdin
    install_hook "$REMOTE/hooks" update 0
    install_hook "$REMOTE/hooks" post-receive 0 stdin
    run_cap gitx push -q origin HEAD:refs/heads/main
    assert_rc 0 push
    assert_contains "$(<"$HLOG/post-receive.stdin")" "refs/heads/main" "post-receive ran with the ref lines"
    assert_contains "$(hook_args update)" "[refs/heads/main]" "update got the ref name"
    assert_eq "$(gitx --git-dir="$REMOTE" rev-parse refs/heads/main)" "$(gitx rev-parse HEAD)" "remote received the commit"
}

run_file_tests
