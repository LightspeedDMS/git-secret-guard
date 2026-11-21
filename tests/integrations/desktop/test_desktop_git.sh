#!/usr/bin/env bash
# shellcheck disable=SC2016
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lifecycle.sh"
# shellcheck source=tests/integrations/desktop/desktop_git.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/desktop_git.sh"

# ^ external the Desktop feature is Linux only; its wrappers and launcher have no meaning on Windows
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="GitHub Desktop on Linux"; fi

dg_begin() {
    lc_begin && dg_fixture || return 1
}

test_the_event_list_matches_githooks_5() {
    local page want got
    dg_begin || return 1
    page=/usr/share/man/man5/githooks.5.gz
    [ -r "$page" ] || skip_test "no githooks(5) page at $page"
    want="$(zcat -- "$page" | sed -n 's/^\.SS "\(.*\)"$/\1/p' | sed 's/\\//g' | grep -vx reference-transaction | LC_ALL=C sort | tr '\n' ' ')"
    dg_run 'printf "%s\n" "${DESKTOP_GIT_EVENTS[@]}" | LC_ALL=C sort | tr "\n" " "'
    assert_rc 0 "the event list prints"
    got="$OUT"
    assert_eq "$got" "$want" "the wrapped events are the sections of githooks(5) except reference-transaction"
    dg_run 'printf "%s" "${#DESKTOP_GIT_EVENTS[@]}"'
    assert_eq "$OUT" 27 "27 events: the 28 of git 2.45 and 2.56 alike, less reference-transaction"
}

test_wrappers_are_symlinks_to_the_shared_file_and_there_is_none_for_reference_transaction() {
    local ev f
    dg_begin || return 1
    dg_run 'desktop_git_hooks_write "$1" "$2"' "$SHARE" "$SANDBOX/dh"
    assert_rc 0 "the hooks directory is written"
    for ev in pre-commit commit-msg pre-push post-checkout post-index-change; do
        f="$SANDBOX/dh/$ev"
        [ -L "$f" ] || fail "$ev is no symbolic link"
        assert_eq "$(readlink "$f")" gsg-desktop-chain "$ev is a relative link to the shared file (copy-safe, ours by its target)"
        [ -x "$f" ] || fail "$ev does not resolve to an executable file"
    done
    assert_no_file "$SANDBOX/dh/reference-transaction" "a repository's own reference-transaction hook is a stated limit, not wrapped (a wrapper costs up to three runs per ref update)"
    [ -x "$SANDBOX/dh/gsg-desktop-chain" ] && [ ! -L "$SANDBOX/dh/gsg-desktop-chain" ] || fail "the shared implementation file is missing or a link"
    assert_contains "$(<"$SANDBOX/dh/gsg-desktop-chain")" "written by install --link-desktop-git" "the shared file carries the marker"
    assert_eq "$(find "$SANDBOX/dh" -mindepth 1 | wc -l)" 28 "27 links and the shared file, nothing else"
}

# ^ invariant dg_scan_begin = the fixture, the real scanners in the hook suite's share dir and its wrappers in $SANDBOX/dh
dg_scan_begin() {
    dg_begin || return 1
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    use_real_tools || return 1
    dg_run 'desktop_git_hooks_write "$1" "$2"' "$SHARE" "$SANDBOX/dh"
    assert_rc 0 "the hooks directory is written"
}

test_the_wrapper_blocks_a_fake_token_in_a_file_and_in_a_message_with_git_2_45() {
    local key
    key="$(fake_aws_key)"
    dg_scan_begin || return 1
    dg_need_old_git
    dg_repo a || return 1
    printf 'k = "%s"\n' "$key" >a.txt
    dgit "$SANDBOX/dh" add a.txt
    dgit "$SANDBOX/dh" commit -q -m t
    assert_rc 1 "a token in a staged file blocks the commit"
    assert_contains "$ERR" "potential secret(s) in lines this commit adds" "the hook's own text is shown"
    no_leak "$key"
    dgit "$SANDBOX/dh" rev-parse -q --verify HEAD
    assert_rc 1 "no commit was made"
    dgit "$SANDBOX/dh" rm -q -f --cached a.txt
    printf 'hello\n' >b.txt
    dgit "$SANDBOX/dh" add b.txt
    dgit "$SANDBOX/dh" commit -q -m "note $key"
    assert_rc 1 "a token only in the message blocks the commit"
    assert_contains "$ERR" "potential secret(s) in the commit message" "the message scan ran"
    no_leak "$key"
    dgit "$SANDBOX/dh" commit -q -m clean
    assert_rc 0 "a clean commit passes"
    assert_contains "$ERR" "git-secret-guard: scanned" "and prints the pass line"
}

test_the_scan_gets_the_same_arguments_and_its_status_is_the_hooks_status() {
    dg_begin && dg_stub_share && dg_stub_git "git version 2.45.3" || return 1
    printf '7' >"$SANDBOX/scan.rc" || return 1
    dg_hook commit-msg /some/COMMIT_EDITMSG
    assert_rc 7 "the status of the scan is the status of the wrapper"
    assert_eq "$(<"$SANDBOX/scan.log")" "/some/COMMIT_EDITMSG" "the message file reached the scan as git passed it"
    rm -f -- "$SANDBOX/scan.log" || return 1
    dg_hook pre-commit
    assert_rc 7 "pre-commit too"
    assert_eq "$(<"$SANDBOX/scan.log")" "" "pre-commit passes no argument"
}

# ^ invariant dg_scan_with TEXT = pre-commit with a stub git answering TEXT; $SANDBOX/scan.log exists afterwards exactly when the scan ran
dg_scan_with() {
    rm -f -- "$SANDBOX/scan.log" || return 1
    dg_stub_git "$1" || return 1
    dg_hook pre-commit
}

test_the_scan_is_skipped_for_git_2_54_and_newer_and_runs_for_older_or_unreadable() {
    local v
    dg_begin && dg_stub_share || return 1
    for v in "git version 2.54.0" "git version 2.56.1" "git version 3.0.0"; do
        dg_scan_with "$v" || return 1
        assert_rc 0 "$v: nothing to scan twice"
        assert_no_file "$SANDBOX/scan.log" "$v: the scan ran although the config hook scans"
    done
    for v in "git version 2.53.1" "git version 1.9.0" "this is no version" ""; do
        dg_scan_with "$v" || return 1
        assert_file "$SANDBOX/scan.log" "[$v]: the scan did not run"
    done
    rm -f -- "$SANDBOX/scan.log" || return 1
    printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/stubgit/git" || return 1
    dg_hook pre-commit
    assert_file "$SANDBOX/scan.log" "a git whose --version fails: the scan did not run"
}

test_other_events_never_scan_and_a_missing_event_or_scan_command_fails() {
    dg_begin && dg_stub_share && dg_stub_git "git version 2.45.3" || return 1
    printf '1' >"$SANDBOX/scan.rc" || return 1
    dg_hook post-commit
    assert_no_file "$SANDBOX/scan.log" "post-commit ran the scan"
    dg_hook gsg-desktop-chain
    assert_rc 1 "the shared file started by its own name"
    assert_contains "$ERR" "was started as gsg-desktop-chain, not under the name of a hook" "says why"
    mkdir -p -- "$SANDBOX/unbaked" && cp -- "$GSG_PROJECT/lib/integrations/desktop/desktop-chain.sh" "$SANDBOX/unbaked/pre-commit" || return 1
    run_cap env -i PATH="$SANDBOX/stubgit:$TEST_BASE_PATH" bash "$SANDBOX/unbaked/pre-commit"
    assert_rc 1 "the unbaked template"
    assert_contains "$ERR" "has no scan command" "says it was never written by install"
}

test_the_check_covers_desktops_default_count_branch_and_its_preview_append_branch() {
    local env_text
    dg_begin || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_check_env "/x y/it'\''s" 2'
    assert_rc 0 "the environment of the default branch ($ERR)"
    env_text="$OUT"
    assert_contains "$env_text" "GIT_CONFIG_COUNT=2" "the default branch of Desktop's renderer.js sets a count of two"
    assert_contains "$env_text" "GIT_CONFIG_KEY_0=credential.helper"$'\n'"GIT_CONFIG_VALUE_0="$'\n'"GIT_CONFIG_KEY_1=credential.helper"$'\n'"GIT_CONFIG_VALUE_1=desktop" "with its two credential.helper entries"
    assert_contains "$env_text" "GIT_CONFIG_PARAMETERS='core.hooksPath=/x y/it'\\''s'" "and our parameter, untouched and with nothing appended"
    assert_not_contains "$env_text" "'credential.helper=desktop'" "the append belongs to the preview branch"
    dg_run 'paths_init && desktop_git_paths && desktop_git_check_env /x 1'
    assert_contains "$OUT" "GIT_CONFIG_PARAMETERS='core.hooksPath=/x' 'credential.helper=' 'credential.helper=desktop'" "the preview branch appends to the parameters"
    assert_not_contains "$OUT" "GIT_CONFIG_COUNT" "and sets no count"
    dg_run 'desktop_git_check_why 13; printf "\n"; desktop_git_check_why 14'
    assert_contains "$OUT" "default (count) branch" "the failure texts name the branch"
}

test_the_hold_applies_to_desktops_own_git_in_a_linking_run_only() {
    dg_begin || return 1
    dg_run 'paths_init && desktop_git_paths; DESKTOP_GIT_FLAG=1; DG_WARN_HELD=0; desktop_git_hold_warning "$DG_GIT"; printf "%s %s" "$?" "$DG_WARN_HELD"'
    assert_eq "$OUT" "0 1" "Desktop's git in a run that links it: held"
    dg_run 'paths_init && desktop_git_paths; DESKTOP_GIT_FLAG=1; DG_WARN_HELD=0; desktop_git_hold_warning /usr/bin/git; printf "%s %s" "$?" "$DG_WARN_HELD"'
    assert_eq "$OUT" "1 0" "another git is never held"
    dg_run 'paths_init && desktop_git_paths; DESKTOP_GIT_FLAG=0; DG_WARN_HELD=0; desktop_git_hold_warning "$DG_GIT"; printf "%s %s" "$?" "$DG_WARN_HELD"'
    assert_eq "$OUT" "1 0" "a plain install holds nothing"
}

# ^ why counts, not time; wrapped checkouts take about 3.7x the plain ones by construction, and a 3x plus 5 s ceiling failed on macOS CI by 65 ms
# ^ invariant a checkout runs post-checkout and post-index-change; each starts one bash (the wrapper) and one git (rev-parse), and the scan never runs
# ^ hazard only the bash shim (loop by path, hooks via PATH) and Desktop's git are counted; the layout test checks reference-transaction
dg_count_summary() {
    LC_ALL=C sort -- "$1" | uniq -c | sed 's/^ *//'
}

test_a_checkout_through_the_wrappers_starts_one_bash_and_one_git_per_hook_run() {
    local -r n=10
    local half=$((n / 2))
    dg_begin && dg_stub_share || return 1
    dg_repo count || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/no-hooks" add a.txt || return 1
    dgit "$SANDBOX/no-hooks" commit -q -m one || return 1
    dgit "$SANDBOX/no-hooks" branch b || return 1
    dg_count_begin || return 1
    dg_checkouts "$SANDBOX/no-hooks" "$n"
    assert_rc 0 "plain checkouts ($ERR)"
    assert_eq "$(dg_count_summary "$SANDBOX/dg.calls")" "$half checkout -q b"$'\n'"$half checkout -q main" "plain: git starts only for the $n checkouts"
    assert_eq "$(dg_count_summary "$SANDBOX/dg.bash")" "1 -c" "plain: bash starts only for the loop"
    : >"$SANDBOX/dg.calls" && : >"$SANDBOX/dg.bash" || return 1
    dg_checkouts "$SANDBOX/dh2" "$n"
    assert_rc 0 "checkouts through the wrappers ($ERR)"
    assert_eq "$(dg_count_summary "$SANDBOX/dg.calls")" "$half checkout -q b"$'\n'"$half checkout -q main"$'\n'"$n rev-parse --git-path hooks/post-checkout"$'\n'"$n rev-parse --git-path hooks/post-index-change" "wrapped: one git call per hook run ($n runs of each of the two hooks) besides the checkouts"
    assert_eq "$(dg_count_summary "$SANDBOX/dg.bash")" "1 -c"$'\n'"$n post-checkout"$'\n'"$n post-index-change" "wrapped: one bash per hook run besides the loop"
    assert_no_file "$SANDBOX/scan.log" "the scan never runs on checkout"
}

test_a_loop_guard_for_this_pid_never_skips_the_scan_and_only_stops_the_exec() {
    dg_begin && dg_stub_share && dg_stub_git "git version 2.45.3" || return 1
    printf '7' >"$SANDBOX/scan.rc" || return 1
    printf '#!/bin/bash\nexport GSG_DESKTOP_CHAIN_PID=$$\nexec "$@"\n' >"$SANDBOX/same-pid" && chmod 755 "$SANDBOX/same-pid" || return 1
    run_cap env -i PATH="$SANDBOX/stubgit:$TEST_BASE_PATH" HOME="$SANDBOX/home" "$SANDBOX/same-pid" "$SANDBOX/dh2/pre-commit"
    assert_rc 7 "a reused pid in the inherited variable still scans and blocks"
    assert_file "$SANDBOX/scan.log" "the scan ran"
    rm -f -- "$SANDBOX/git.calls" || return 1
    run_cap env -i PATH="$SANDBOX/stubgit:$TEST_BASE_PATH" HOME="$SANDBOX/home" "$SANDBOX/same-pid" "$SANDBOX/dh2/post-commit"
    assert_rc 0 "the guard stops the exec of a repository hook"
    assert_no_file "$SANDBOX/git.calls" "without asking git anything"
}

test_only_our_own_entry_leaves_the_config_parameters_and_an_unclear_value_is_emptied() {
    local dh2="$SANDBOX/dh2"
    dg_begin && dg_stub_share && dg_stub_git "git version 2.45.3" || return 1
    DG_PARAMS="'user.x=1' 'core.hooksPath=$dh2' 'credential.helper=desktop'" dg_hook post-checkout
    assert_rc 0 "post-checkout with other entries around ours"
    assert_eq "$(<"$SANDBOX/git.params")" "'user.x=1' 'credential.helper=desktop'" "only our own entry was dropped for the git call"
    dg_stub_git "git version 2.45.3" || return 1
    DG_PARAMS="'user.x=1'" dg_hook post-checkout
    assert_rc 0 "post-checkout without our entry"
    assert_eq "$(<"$SANDBOX/git.params")" "" "our entry is not there: the value cannot be told apart and is emptied"
    dg_stub_git "git version 2.45.3" || return 1
    DG_PARAMS="'core.hooksPath=$dh2' 'core.hooksPath=$dh2'" dg_hook post-checkout
    assert_rc 0 "post-checkout with our entry twice"
    assert_eq "$(<"$SANDBOX/git.params")" "" "our entry twice is ambiguous and is emptied"
}

test_a_user_include_that_sets_the_hooks_path_resolves_as_git_resolves_it() {
    local DG_PARAMS_PREFIX="'include.path=$SANDBOX/inc.cfg'"
    dg_scan_begin || return 1
    printf '[core]\n\thooksPath = %s/userhooks\n' "$SANDBOX" >"$SANDBOX/inc.cfg" || return 1
    dg_repo_hook "$SANDBOX/userhooks" pre-commit || return 1
    printf '3' >"$SANDBOX/chain.rc" || return 1
    rm -f -- "$SANDBOX/chain.log" || return 1
    dg_repo included || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -m one
    assert_rc 1 "the hook the user's include names blocks the commit ($ERR)"
    assert_file "$SANDBOX/chain.log" "and it ran"
}

test_stale_temp_links_and_files_are_removed_by_unlink_so_the_directory_goes() {
    local hooks="$SANDBOX/xdg/data/git-secret-guard/desktop-hooks"
    dg_begin || return 1
    mkdir -p -- "$SANDBOX/xdg/data/git-secret-guard" || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_hooks_write "$GSG_ROOT" "$DG_HOOKS"'
    assert_rc 0 "the hooks directory is written ($ERR)"
    ln -s gsg-desktop-chain "$hooks/.pre-commit.new.123" && cp -- "$hooks/gsg-desktop-chain" "$hooks/gsg-desktop-chain.new.AbC123" || return 1
    ln -s /nonexistent-elsewhere "$hooks/.post-commit.new.9" || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_unlink_files; rc=$?; printf "%s" "$DG_REMOVED"; exit $rc'
    assert_rc 0 "unlink with leftovers"
    assert_eq "$OUT" 30 "27 wrappers, the shared file and the two leftovers of ours were removed"
    [ -L "$hooks/.post-commit.new.9" ] || fail "a link that is not ours was removed"
    rm -f -- "$hooks/.post-commit.new.9" || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_unlink_files'
    assert_rc 0 "unlink once only foreign files were gone"
    assert_no_file "$hooks" "the directory is gone"
}

test_an_awkward_hooks_dir_path_is_matched_literally_when_our_entry_is_removed() {
    local dir="$SANDBOX/q'*[x]dir" esc
    dg_begin && dg_stub_share && dg_stub_git "git version 2.45.3" || return 1
    dg_run 'desktop_git_hooks_write "$1" "$2"' "$SANDBOX/fshare" "$dir"
    assert_rc 0 "wrappers in a directory with a quote and glob characters in its name ($ERR)"
    esc="${dir//\'/\'\\\'\'}"
    run_cap env -i PATH="$SANDBOX/stubgit:$TEST_BASE_PATH" HOME="$SANDBOX/home" GIT_CONFIG_PARAMETERS="'user.x=1' 'core.hooksPath=$esc' 'b=2'" "$dir/post-checkout"
    assert_rc 0 "the wrapper runs"
    assert_eq "$(<"$SANDBOX/git.params")" "'user.x=1' 'b=2'" "exactly our entry went, the others stayed"
}

test_a_non_commit_event_costs_exactly_one_git_call() {
    dg_begin && dg_stub_share && dg_stub_git "git version 2.45.3" || return 1
    dg_hook post-checkout a b 1
    assert_rc 0 "post-checkout through a wrapper"
    assert_eq "$(<"$SANDBOX/git.calls")" "rev-parse --git-path hooks/post-checkout" "one git call, the one that finds the repository's hook"
    rm -f -- "$SANDBOX/git.calls" || return 1
    dg_hook post-index-change 0 1
    assert_eq "$(<"$SANDBOX/git.calls")" "rev-parse --git-path hooks/post-index-change" "post-index-change is on the same fast path"
}

test_an_exec_loop_through_a_copy_of_the_wrapper_in_the_repository_ends() {
    local DG_TIMEOUT=30
    dg_scan_begin || return 1
    dg_repo loopcopy || return 1
    dgit "$SANDBOX/dh" config core.hooksPath .loop || return 1
    mkdir -p .loop && cp -- "$SANDBOX/dh/gsg-desktop-chain" .loop/post-commit || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -m one
    assert_rc 0 "a commit whose post-commit hook is a copy of the wrapper ends ($ERR)"
}

test_an_empty_repository_hooks_path_runs_no_hook_as_git_does() {
    dg_scan_begin || return 1
    dg_repo emptypath || return 1
    rm -f -- "$SANDBOX/chain.log" || return 1
    dgit "$SANDBOX/dh" config core.hooksPath "" || return 1
    dg_repo_hook .git/hooks pre-commit || return 1
    printf '4' >"$SANDBOX/chain.rc" || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -m one
    assert_rc 0 "git 2.45 runs no hook with an empty core.hooksPath, and neither does the wrapper ($ERR)"
    assert_no_file "$SANDBOX/chain.log" ".git/hooks/pre-commit was not run"
}

test_a_non_executable_repository_hook_gets_gits_hint_unless_advice_is_off() {
    dg_scan_begin || return 1
    dg_repo hint || return 1
    dg_repo_hook .git/hooks pre-commit || return 1
    chmod 644 .git/hooks/pre-commit || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -m one
    assert_rc 0 "a hook without the executable bit is ignored ($ERR)"
    assert_contains "$ERR" "hint: The '.git/hooks/pre-commit' hook was ignored because it's not set as executable." "git's own hint, with the path as git would print it"
    assert_contains "$ERR" 'hint: You can disable this warning with `git config advice.ignoredHook false`.' "and its second line"
    dgit "$SANDBOX/dh" config advice.ignoredHook false || return 1
    dgit "$SANDBOX/dh" commit -q --allow-empty -m two
    assert_rc 0 "the next commit ($ERR)"
    assert_not_contains "$ERR" "hint:" "advice.ignoredHook=false silences it"
}

test_a_tilde_hooks_path_in_the_repository_is_resolved_as_git_resolves_it() {
    dg_scan_begin || return 1
    dg_repo tilde || return 1
    # shellcheck disable=SC2088
    dgit "$SANDBOX/dh" config core.hooksPath '~/hk' || return 1
    dg_repo_hook "$SANDBOX/home/hk" pre-commit || return 1
    printf '3' >"$SANDBOX/chain.rc" || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -m one
    assert_rc 1 "the hook below ~ blocks the commit with its status"
    assert_file "$SANDBOX/chain.log" "the hook named by ~/hk ran"
}

test_root_commits_amends_and_partial_commits_are_scanned_with_git_2_45() {
    local key
    key="$(fake_aws_key)"
    dg_scan_begin || return 1
    dg_need_old_git
    dg_repo amend || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -m root
    assert_rc 0 "a clean root commit ($ERR)"
    dgit "$SANDBOX/dh" commit -q --amend -m "amended $key"
    assert_rc 1 "an amend whose message holds a token"
    assert_contains "$ERR" "potential secret(s) in the commit message" "the message scan runs for an amend of a root commit"
    dgit "$SANDBOX/dh" commit -q --amend -m "amended clean"
    assert_rc 0 "a clean amend of the root commit ($ERR)"
    printf 'k = "%s"\n' "$key" >>a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -a -m "with -a"
    assert_rc 1 "commit -a with a token"
    assert_contains "$ERR" "potential secret(s) in lines this commit adds" "the lines scan sees the tree of -a"
    dgit "$SANDBOX/dh" commit -q -m "only a.txt" -- a.txt
    assert_rc 1 "commit <path> (a temporary index) with a token"
    assert_contains "$ERR" "potential secret(s) in lines this commit adds" "the lines scan sees the tree of --only"
    no_leak "$key"
}

test_a_husky_style_core_hooks_path_in_the_repository_still_runs() {
    dg_scan_begin || return 1
    dg_need_old_git
    dg_repo husky || return 1
    dgit "$SANDBOX/dh" config core.hooksPath .husky || return 1
    dg_repo_hook .husky pre-commit || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    printf '3' >"$SANDBOX/chain.rc" || return 1
    dgit "$SANDBOX/dh" commit -q -m one
    assert_rc 1 "the repository's own hook blocks the commit with its status"
    assert_contains "$ERR" "git-secret-guard: scanned" "the scan ran first"
    assert_file "$SANDBOX/chain.log" "the repository hook did not run (core.hooksPath was .husky, scope local)"
    printf '0' >"$SANDBOX/chain.rc" || return 1
    dgit "$SANDBOX/dh" commit -q -m two
    assert_rc 0 "the repository hook passing lets the commit through"
}

test_a_hook_in_dot_git_hooks_still_runs_and_a_non_executable_one_does_not() {
    dg_scan_begin || return 1
    dg_repo plain || return 1
    dg_repo_hook .git/hooks pre-commit || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    printf '4' >"$SANDBOX/chain.rc" || return 1
    dgit "$SANDBOX/dh" commit -q -m one
    assert_rc 1 ".git/hooks/pre-commit blocks with its status"
    assert_file "$SANDBOX/chain.log" ".git/hooks/pre-commit did not run"
    chmod 644 .git/hooks/pre-commit || return 1
    rm -f -- "$SANDBOX/chain.log" || return 1
    dgit "$SANDBOX/dh" commit -q -m two
    assert_rc 0 "a hook without the executable bit is ignored, as git ignores it"
    assert_no_file "$SANDBOX/chain.log" "and did not run"
}

test_pre_push_gets_its_arguments_its_stdin_and_the_hooks_status() {
    local remote="$SANDBOX/remote.git" sha
    dg_scan_begin || return 1
    dgit "$SANDBOX/no-hooks" init -q --bare "$remote" || return 1
    dg_repo pushing || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -m one || return 1
    dgit "$SANDBOX/dh" rev-parse HEAD || return 1
    sha="$OUT"
    dgit "$SANDBOX/dh" remote add origin "$remote" || return 1
    dg_repo_hook .git/hooks pre-push || return 1
    printf '5' >"$SANDBOX/chain.rc" || return 1
    dgit "$SANDBOX/dh" push -q origin HEAD:refs/heads/main
    assert_rc 1 "the push is refused because the repository's pre-push hook failed"
    assert_file "$SANDBOX/chain.log" "the pre-push hook did not run"
    assert_contains "$(<"$SANDBOX/chain.log")" "pre-push origin $remote" "the remote name and url are its arguments"
    assert_contains "$(<"$SANDBOX/chain.log")" "$sha refs/heads/main" "the refs git writes on stdin reached it"
    printf '0' >"$SANDBOX/chain.rc" || return 1
    dgit "$SANDBOX/dh" push -q origin HEAD:refs/heads/main
    assert_rc 0 "the push goes through when the hook passes"
}

test_a_repository_that_names_our_own_directory_as_its_hooks_path_does_not_recurse() {
    dg_scan_begin || return 1
    dg_repo loop || return 1
    dgit "$SANDBOX/dh" config core.hooksPath "$SANDBOX/dh" || return 1
    printf 'hello\n' >a.txt || return 1
    dgit "$SANDBOX/dh" add a.txt || return 1
    dgit "$SANDBOX/dh" commit -q -m one
    assert_rc 0 "a commit with our own directory as the repository's hooks path ends"
}

test_a_git_that_cannot_say_where_the_hooks_are_stops_the_wrapper_with_a_message() {
    dg_begin && dg_stub_share || return 1
    printf '#!/bin/sh\ncase "$1" in --version) echo "git version 2.45.3" ;; *) exit 128 ;; esac\n' >"$SANDBOX/stubgit/git" || return 1
    chmod 755 "$SANDBOX/stubgit/git" || return 1
    dg_hook post-commit
    assert_rc 1 "git config failing is no reason to skip the repository's hook unseen"
    assert_contains "$ERR" "its own post-commit hook was NOT run" "the wrapper says what was skipped"
}

test_the_launcher_exec_survives_desktop_entry_parsing_and_git_parameter_parsing_for_awkward_paths() {
    local dir file="$SANDBOX/launcher.desktop" out="$SANDBOX/launched.argv"
    local -a argv=() dirs=("$SANDBOX/plain dir" "$SANDBOX/it's" "$SANDBOX/say \"hi\"" "$SANDBOX/\$HOME \`id\` 100%" "$SANDBOX/back\\slash" "$SANDBOX/all ' \" \$ \` \\ % together")
    dg_begin || return 1
    python3 -I -c 'import gi; gi.require_version("Gio", "2.0")' 2>/dev/null || skip_test "PyGObject (Gio) is not available"
    for dir in "${dirs[@]}"; do
        dg_run 'desktop_git_launcher_text "$1" "$2" >"$3"' "$DG_LAUNCHER_SYS" "$dir" "$file"
        assert_rc 0 "the launcher is written for [$dir]"
        run_cap dg_launch "$file" "$out"
        assert_rc 0 "[$dir]: GLib launches it ($ERR)"
        mapfile -d '' -t argv <"$out"
        assert_eq "${#argv[@]}" 2 "[$dir]: the variable and the program reach env"
        assert_eq "${argv[1]}" github-desktop "[$dir]: Desktop is started as before"
        assert_eq "${argv[0]%%=*}" GIT_CONFIG_PARAMETERS "[$dir]: the variable"
        run_cap env -i HOME="$SANDBOX/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_PARAMETERS="${argv[0]#*=}" "$GIT" config --get core.hooksPath
        assert_rc 0 "[$dir]: git accepts the parameters ($ERR)"
        assert_eq "$OUT" "$dir" "[$dir]: git reads the directory back exactly"
        assert_eq "$(sed -n '1p' "$file")" "# git-secret-guard: written by install --link-desktop-git; undone by unlink-desktop-git" "[$dir]: the marker is the first line"
    done
    assert_eq "$(grep -c '' "$file")" "$(($(grep -c '' "$DG_LAUNCHER_SYS") + 1))" "the copy has the system entry's lines plus the marker"
}

test_the_launcher_is_written_once_from_the_system_entry_and_a_foreign_one_is_kept() {
    dg_begin || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_launcher_write && printf "%s" "${DG_CHANGED:-0}"'
    assert_rc 0 "the launcher is written ($ERR)"
    assert_eq "$OUT" 1 "a new file is a change"
    assert_eq "$(stat -c %a "$DG_LAUNCHER_USER")" 644 "mode 644"
    assert_contains "$(<"$DG_LAUNCHER_USER")" "Name=GitHub Desktop" "the system entry's lines are kept"
    dg_run 'paths_init && desktop_git_paths && DG_CHANGED=0 && desktop_git_launcher_write && printf "%s" "$DG_CHANGED"'
    assert_eq "$OUT" 0 "a rerun with nothing new writes nothing"
    printf 'mine\n' >"$DG_LAUNCHER_USER" || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_launcher_write'
    assert_rc 1 "a launcher that is not ours is not replaced"
    assert_contains "$ERR" "$DG_LAUNCHER_USER is not a file install --link-desktop-git wrote" "and is named"
    assert_eq "$(<"$DG_LAUNCHER_USER")" mine "its content is untouched"
}

test_unlink_removes_only_files_with_the_marker_and_names_what_it_keeps() {
    local hooks="$SANDBOX/xdg/data/git-secret-guard/desktop-hooks"
    dg_begin || return 1
    mkdir -p -- "$SANDBOX/xdg/data/git-secret-guard" || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_hooks_write "$GSG_ROOT" "$DG_HOOKS" && desktop_git_launcher_write'
    assert_rc 0 "the link is written ($ERR)"
    rm -f -- "$hooks/post-commit" && printf 'mine\n' >"$hooks/post-commit" || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_unlink_files; rc=$?; printf "%s" "$DG_REMOVED"; exit $rc'
    assert_rc 0 "unlink succeeds with a foreign file in the directory"
    assert_eq "$OUT" 28 "26 wrappers, the shared file and the launcher were removed"
    assert_contains "$ERR" "$hooks/post-commit was not written by git-secret-guard; left in place" "the kept file is named"
    assert_file "$hooks/post-commit" "the foreign file is still there"
    assert_no_file "$DG_LAUNCHER_USER" "the launcher is gone"
    rm -f -- "$hooks/post-commit" || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_unlink_files; rc=$?; printf "%s" "$DG_REMOVED"; exit $rc'
    assert_rc 0 "unlink with nothing left"
    assert_eq "$OUT" 0 "nothing was removed"
    assert_no_file "$hooks" "the empty directory is gone"
}

# ^ invariant dg_check_hooks makes $SANDBOX/ch with a plain pre-commit and commit-msg (no wrapper), acting on the fake key as $SANDBOX/ch.knob says
# ^ invariant the pre-commit also chains to .husky and .git/hooks as the CHAIN knob says (none, husky or both)
# ^ security the key shape is put together from fragments when the hooks are written; no literal of the shape is in this file
dg_check_hooks() {
    local pre msg key
    key="$(printf '%s%s' 'AKI' 'A')"
    IFS= read -r -d '' pre <<'EOF' || true
#!/bin/sh
. "@KNOB@"
d="$(git diff --cached)" || exit 9
case "$d" in
*@KEY@*)
    case "${GIT_CONFIG_PARAMETERS-}" in *credential.helper=desktop*) if [ "$PREVIEW" = pass ]; then exit 0; fi ;; esac
    if [ "${GIT_CONFIG_COUNT-}" = 2 ] && [ "$COUNT" = pass ]; then exit 0; fi
    case "$PRE" in
    pass) exit 0 ;;
    notext) echo "blocked" >&2; exit 1 ;;
    esac
    echo "git-secret-guard: potential secret(s) in lines this commit adds" >&2
    exit 1 ;;
esac
n="$(cat "@COUNT@" 2>/dev/null || echo 0)"
n=$((n + 1))
echo "$n" >"@COUNT@"
if [ "$n" -gt 1 ]; then
    case "$CLEAN" in
    fail) echo "a clean commit is refused" >&2; exit 1 ;;
    silent) ;;
    *) echo "git-secret-guard: scanned" >&2 ;;
    esac
fi
if [ "$CHAIN" != none ] && [ -x .husky/pre-commit ]; then .husky/pre-commit || exit 1; fi
if [ "$CHAIN" = both ] && [ -x .git/hooks/pre-commit ]; then .git/hooks/pre-commit || exit 1; fi
exit 0
EOF
    IFS= read -r -d '' msg <<'EOF' || true
#!/bin/sh
. "@KNOB@"
m="$(cat "$1")"
case "$m" in
*@KEY@*)
    case "$MSG" in
    pass) exit 0 ;;
    notext) echo "blocked" >&2; exit 1 ;;
    esac
    echo "git-secret-guard: potential secret(s) in the commit message" >&2
    exit 1 ;;
esac
exit 0
EOF
    mkdir -p -- "$SANDBOX/ch" || return 1
    pre="${pre//@KEY@/$key}" && pre="${pre//@KNOB@/$SANDBOX/ch.knob}" && pre="${pre//@COUNT@/$SANDBOX/ch.n}" || return 1
    msg="${msg//@KEY@/$key}" && msg="${msg//@KNOB@/$SANDBOX/ch.knob}" || return 1
    printf '%s\n' "$pre" >"$SANDBOX/ch/pre-commit" && printf '%s\n' "$msg" >"$SANDBOX/ch/commit-msg" || return 1
    chmod 755 "$SANDBOX/ch/pre-commit" "$SANDBOX/ch/commit-msg" || return 1
}

# ^ invariant dg_check_knob [NAME=VALUE]... sets the knobs of dg_check_hooks; the defaults make every step of the check hold
dg_check_knob() {
    printf '%s\n' PRE=block MSG=block CLEAN=ok CHAIN=both PREVIEW=block COUNT=block "$@" >"$SANDBOX/ch.knob"
}

# ^ invariant dg_check_run OVERRIDE runs desktop_git_check_run on $SANDBOX/ch after the shell text OVERRIDE redefined some of the product's functions
dg_check_run() {
    printf '%s\n' "${1:-:}" >"$SANDBOX/ch.override" || return 1
    rm -f -- "$SANDBOX/ch.n" || return 1
    dg_run 'lifecycle_require_git && paths_init && desktop_git_paths && . "$2" && desktop_git_check_run "$1"' "$SANDBOX/ch" "$SANDBOX/ch.override"
}

# ^ invariant prints the shell text dropping the credential entries of Desktop's environment MODE (1 = the appended parameters, 2 = the count entries)
dg_check_drop_credentials() {
    local text
    IFS= read -r -d '' text <<'EOF' || true
eval "orig_$(declare -f desktop_git_check_env)"
desktop_git_check_env() {
    if [ "${2:-0}" -ne @MODE@ ]; then orig_desktop_git_check_env "$@"; return; fi
    orig_desktop_git_check_env "$@" | sed -e "s/ 'credential[.]helper=.*//" -e '/^GIT_CONFIG_\(COUNT\|KEY_\|VALUE_\)/d'
}
EOF
    printf '%s' "${text//@MODE@/$1}"
}

test_every_outcome_of_the_desktop_check_is_named_with_its_own_text() {
    local row code knobs how why override
    local -a kn
    local -a rows=(
        "2|CHAIN=both|repo|the scratch repository could not be set up (check status 2)"
        "3|PRE=pass|none|a commit of a fake token in a file was NOT blocked"
        "4|PRE=notext|none|a commit of a fake token in a file failed, but not with the findings text of the hook"
        "5|MSG=pass|none|a commit of a fake token only in the message was NOT blocked"
        "6|MSG=notext|none|a commit with a fake token in its message failed, but not with the message findings text"
        "7|CLEAN=fail|none|a clean commit failed"
        "8|CLEAN=silent|none|a clean commit printed no git-secret-guard summary line"
        "9|CHAIN=none|none|a repository hook named by its own core.hooksPath (husky style) did not run"
        "10|CHAIN=husky|none|a repository hook in .git/hooks did not run"
        "11|CHAIN=both|env1|the credential parameters of Desktop's preview branch (appended to GIT_CONFIG_PARAMETERS) did not coexist with core.hooksPath"
        "12|PREVIEW=pass|none|a commit of a fake token was NOT blocked in Desktop's preview branch (credential parameters appended to ours)"
        "13|CHAIN=both|env2|the credential entries of Desktop's default (count) branch (GIT_CONFIG_COUNT=2) did not coexist with core.hooksPath"
        "14|COUNT=pass|none|a commit of a fake token was NOT blocked in Desktop's default (count) branch (GIT_CONFIG_COUNT=2 beside our parameter)"
    )
    dg_begin || return 1
    dg_need_old_git
    dg_check_hooks || return 1
    for row in "${rows[@]}"; do
        IFS='|' read -r code knobs how why <<<"$row"
        read -ra kn <<<"$knobs"
        dg_check_knob "${kn[@]}" || return 1
        case "$how" in
            repo) override='desktop_git_check_repo_hook() { return 2; }' ;;
            env1) override="$(dg_check_drop_credentials 1)" ;;
            env2) override="$(dg_check_drop_credentials 2)" ;;
            *) override=: ;;
        esac
        dg_check_run "$override"
        assert_rc 1 "check outcome $code: the check fails ($ERR)"
        assert_eq "$ERR" "git-secret-guard: checked through GitHub Desktop's git: $why" "check outcome $code: the failure is named with its own text"
        assert_eq "$OUT" "" "check outcome $code: no success line is printed"
    done
}

test_a_hooks_directory_that_holds_every_step_of_the_desktop_check_passes_it_and_leaves_no_scratch_directory() {
    dg_begin || return 1
    dg_need_old_git
    dg_check_hooks && dg_check_knob || return 1
    mkdir -p -- "$SANDBOX/tmp" || return 1
    set_env TMPDIR="$SANDBOX/tmp"
    dg_check_run
    assert_rc 0 "the check passes ($ERR)"
    assert_contains "$OUT" "git-secret-guard: checked through GitHub Desktop's own git with the launcher's environment: a fake token in a file and in a message were blocked, a clean commit was scanned" "the success line names what held"
    assert_contains "$OUT" "Desktop's credential parameters coexist in its default (count) branch and in its preview (append) branch" "in both branches"
    assert_eq "$ERR" "" "nothing is said on stderr"
    assert_eq "$(find "$SANDBOX/tmp" -mindepth 1 | wc -l)" 0 "the scratch directory is removed"
}

run_file_tests
