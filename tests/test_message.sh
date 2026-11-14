#!/usr/bin/env bash
# ^ see doc:docs/scan.md#the-commit-message; the commit-msg event scans the message file git hands the hook, one scan file named COMMIT_EDITMSG
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CALLS="" MARKER=""
begin() {
    new_repo "$1" || return 1
    CALLS="$SANDBOX/calls-$1"
    MARKER="$(new_marker)"
    enable_message_hook
    set_env STUB_LOG="$CALLS" STUB_MARKER="$MARKER"
}
tf_runs() { local n=0; if [ -f "$CALLS" ]; then n="$(grep -c '^trufflehog ' "$CALLS")"; fi; printf '%s' "$n"; }

test_a_clean_message_is_scanned_as_one_file_and_prints_only_the_pass_line() {
    begin clean || return 1
    set_env STUB_RECORD="$SANDBOX/record-clean"
    stage_file src/app.txt one
    gitx commit -q --no-verify -m base
    stage_file src/app.txt one two
    commit_cap "fix: a clean subject"
    assert_rc 0 commit
    assert_empty "$OUT" "stdout stays empty"
    assert_pass_line_only "$ERR" "the commit-msg run adds no line to the pass line"
    assert_eq "$(tf_runs)" 2 "trufflehog ran once for the lines and once for the message"
    assert_eq "$(tail -n 2 "$SANDBOX/record-clean.trufflehog")" "== COMMIT_EDITMSG
fix: a clean subject" "the last scan held the message and nothing else"
}

test_a_finding_in_the_message_blocks_as_commit_message_line_and_never_prints_the_value() {
    begin finding || return 1
    stage_file src/app.txt one
    set_env STUB_TF_FINDINGS="AWS|false|COMMIT_EDITMSG|2" STUB_MARKER="$MARKER"
    printf 'subject\n%s\n' "line two $MARKER" >"$SANDBOX/msg-finding"
    # ^ why run the hook by hand, not through git commit; the stub reports its finding for the lines scan too and pre-commit would block first
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SHARE/hooks/secret-scan" "$SANDBOX/msg-finding"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "potential secret(s) in the commit message" "the heading names the message"
    assert_contains "$ERR" "commit message:2" "the message and its line"
    assert_not_contains "$ERR" "COMMIT_EDITMSG" "the scan file name stays internal"
    assert_contains "$ERR" "git commit --no-verify" "bypass hint"
    no_leak "$MARKER"
}

# ^ invariant runs the hook by hand on a message file, as git does for commit-msg (path as the one argument), and records what both scanners saw
run_message_hook() {
    set_env STUB_RECORD="$SANDBOX/record-$1"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SHARE/hooks/secret-scan" "$2"
}

# ^ invariant builds a message file as commit -v writes it with comment char ; (subject, comments, cut block, the text from stdin last)
verbose_message() {
    local sc=' ------------------------ >8 ------------------------'
    {
        printf 'subject\n\n; Please enter the commit message.\n;\n; On branch main\n'
        printf ';%s\n; Do not modify or remove the line above.\n; Everything below it will be ignored.\n;\n; Changes to be committed:\n' "$sc"
        cat
    } >"$1"
}

# ^ invariant a repository with the removed line "gone MARKER" staged; the diff of git holds the marker in a removed line
verbose_repo() {
    printf 'keep\ngone %s\n' "$MARKER" >src.txt && gitx add src.txt && gitx commit -q --no-verify -m base || return 1
    printf 'keep\nnew line\n' >src.txt && gitx add src.txt
}

test_the_scan_file_blanks_gits_own_verbose_diff_and_keeps_the_numbering() {
    begin cut || return 1
    verbose_repo || return 1
    gitx diff --cached | verbose_message "$SANDBOX/msg-cut"
    run_message_hook cut "$SANDBOX/msg-cut"
    assert_rc 0 "clean"
    assert_empty "$ERR" "a clean message prints nothing"
    assert_not_contains "$(<"$SANDBOX/record-cut.trufflehog")" "$MARKER" "the removed line of git's own diff is not scanned"
    assert_not_contains "$(<"$SANDBOX/record-cut.trufflehog")" "diff --git" "nor is the rest of it"
    assert_contains "$(<"$SANDBOX/record-cut.trufflehog")" "; Changes to be committed:" "the comment lines above and below the cut stay"
    assert_eq "$(($(wc -l <"$SANDBOX/record-cut.trufflehog") - 1))" "$(wc -l <"$SANDBOX/msg-cut")" "the diff lines are blank, so line N of the scan file is line N of the message"
}

# ^ invariant a stand-in clean filter counts its runs in $SANDBOX/filter.log; git diff of the work tree runs it, git diff --cached never does
test_the_message_run_never_runs_a_clean_filter_and_scans_the_worktree_part() {
    begin filter || return 1
    printf '#!/bin/sh\necho run >>%q\ncat\n' "$SANDBOX/filter.log" >"$SANDBOX/clean.sh" && chmod 755 "$SANDBOX/clean.sh" || return 1
    gitx config filter.x.clean "$SANDBOX/clean.sh" && printf '*.txt filter=x\n' >.gitattributes || return 1
    printf 'one\n' >w.txt && gitx add .gitattributes w.txt && gitx commit -q --no-verify -m base || return 1
    printf 'one\nunstaged %s\n' "$MARKER" >w.txt && printf 'staged\n' >s.dat && gitx add s.dat || return 1
    {
        gitx -c diff.mnemonicPrefix=true diff --cached
        printf ';%s\n; Changes not staged for commit:\n' ' --------------------------------------------------'
        gitx -c diff.mnemonicPrefix=true diff
    } | verbose_message "$SANDBOX/msg-filter"
    rm -f -- "$SANDBOX/filter.log"
    run_message_hook filter "$SANDBOX/msg-filter"
    assert_eq "$(if [ -f "$SANDBOX/filter.log" ]; then wc -l <"$SANDBOX/filter.log"; else echo 0; fi | tr -d ' ')" 0 "no clean filter ran during the message run"
    assert_contains "$(<"$SANDBOX/record-filter.trufflehog")" "unstaged $MARKER" "the work tree part of -v -v is scanned, it is in no tree"
    assert_not_contains "$(<"$SANDBOX/record-filter.trufflehog")" "+++ i/s.dat" "the staged part of git's diff is still blanked"
}

test_a_hanging_git_diff_is_a_mismatch_bounded_by_the_timeout() {
    begin hang || return 1
    verbose_repo || return 1
    mkdir -p -- "$SANDBOX/fakegit" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = diff ] && exec sleep 60; done\nexec %q "$@"\n' "$GIT" >"$SANDBOX/fakegit/git" && chmod 755 "$SANDBOX/fakegit/git" || return 1
    gitx diff --cached | verbose_message "$SANDBOX/msg-hang"
    use_stubs "SCAN_TIMEOUT_SECONDS=2"
    set_env PATH="$SANDBOX/fakegit:$REAL_HOME/.local/bin:$TEST_BASE_PATH"
    SECONDS=0
    run_message_hook hang "$SANDBOX/msg-hang"
    if [ "$SECONDS" -gt 30 ]; then fail "the message run took ${SECONDS}s, the diff was not bounded by the timeout"; fi
    assert_rc 0 "clean"
    assert_contains "$(<"$SANDBOX/record-hang.trufflehog")" "gone $MARKER" "a diff that could not be rebuilt in time is a mismatch and is scanned"
}

# ^ invariant hidden text is only ever a real diff between HEAD or HEAD^ and the staged tree; its removed lines are in history, its added lines in this commit
test_a_diff_against_head_parent_is_hidden_on_an_ordinary_commit_because_its_removed_lines_are_in_history() {
    begin parentdiff || return 1
    printf 'gone %s\n' "$MARKER" >secret.txt && gitx add secret.txt && gitx commit -q --no-verify -m leak || return 1
    printf 'clean\n' >secret.txt && gitx add secret.txt && gitx commit -q --no-verify -m remove || return 1
    printf 'more\n' >other.txt && gitx add other.txt || return 1
    gitx diff --cached HEAD^ | verbose_message "$SANDBOX/msg-parent"
    run_message_hook parent "$SANDBOX/msg-parent"
    assert_rc 0 "clean"
    assert_not_contains "$(<"$SANDBOX/record-parent.trufflehog")" "$MARKER" "the removed line comes from HEAD^, a commit already in history"
    assert_not_contains "$(<"$SANDBOX/record-parent.trufflehog")" "diff --git" "the matching diff is blanked"
}

test_a_crlf_diff_below_the_cut_matches_byte_for_byte_and_is_blanked() {
    begin crlf || return 1
    printf 'keep\r\ngone %s\r\n' "$MARKER" >c.txt && gitx add c.txt && gitx commit -q --no-verify -m base || return 1
    printf 'keep\r\nnew line\r\n' >c.txt && gitx add c.txt || return 1
    gitx diff --cached | verbose_message "$SANDBOX/msg-crlf"
    # ^ why tr, not grep; GNU grep may read a file in text mode on Git for Windows and hide the carriage returns it is asked about
    assert_eq "$(tr -cd '\r' <"$SANDBOX/msg-crlf" | wc -c | tr -d ' ')" 3 "the fixture holds the carriage returns of its three content lines"
    run_message_hook crlf "$SANDBOX/msg-crlf"
    assert_not_contains "$(<"$SANDBOX/record-crlf.trufflehog")" "$MARKER" "carriage returns reach awk and cmp unchanged, the diff matches"
}

test_a_diff_with_no_newline_at_end_of_file_matches_and_a_missing_final_newline_is_normalised() {
    begin nonl || return 1
    printf 'keep\ngone %s' "$MARKER" >n.txt && gitx add n.txt && gitx commit -q --no-verify -m base || return 1
    printf 'keep\nnew line' >n.txt && gitx add n.txt || return 1
    gitx diff --cached | verbose_message "$SANDBOX/msg-nonl"
    if ! grep -q 'No newline at end of file' "$SANDBOX/msg-nonl"; then fail "the fixture has no no-newline marker"; fi
    run_message_hook nonl "$SANDBOX/msg-nonl"
    assert_not_contains "$(<"$SANDBOX/record-nonl.trufflehog")" "$MARKER" "git's own no-newline marker line is part of the match"
    printf '%s' "$(<"$SANDBOX/msg-nonl")" >"$SANDBOX/msg-nonl2"
    run_message_hook nonl2 "$SANDBOX/msg-nonl2"
    assert_not_contains "$(<"$SANDBOX/record-nonl2.trufflehog")" "$MARKER" "a message file without its last newline is read as if it had it: the same lines, nothing else"
}

test_a_root_commit_amend_diff_matches_through_the_scratch_empty_tree() {
    begin rootamend || return 1
    local objs before after
    printf 'added %s\n' "$MARKER" >a.txt && gitx add a.txt && gitx commit -q --no-verify -m root || return 1
    {
        printf 'diff --git a/a.txt b/a.txt\nnew file mode 100644\nindex 0000000..%s\n--- /dev/null\n+++ b/a.txt\n@@ -0,0 +1 @@\n' "$(gitx rev-parse --short :a.txt)"
        printf '+added %s\n' "$MARKER"
    } | verbose_message "$SANDBOX/msg-root"
    objs="$(gitx rev-parse --absolute-git-dir)/objects"
    before="$(find "$objs" -type f | wc -l | tr -d ' ')"
    run_message_hook root "$SANDBOX/msg-root"
    after="$(find "$objs" -type f | wc -l | tr -d ' ')"
    assert_not_contains "$(<"$SANDBOX/record-root.trufflehog")" "$MARKER" "the empty tree is the base of a root amend, the diff matches"
    assert_eq "$after" "$before" "the scratch empty tree writes no object into the repository"
}

# shellcheck disable=SC2016
test_the_message_lib_git_wrapper_fails_without_a_timeout_binary_or_setting() {
    run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/common.sh" && source "$1/lib/message.sh" || exit 9
        TIMEOUT_BIN="" SCAN_TIMEOUT_SECONDS=5 _message_git --version >/dev/null; a=$?
        TIMEOUT_BIN="$2" SCAN_TIMEOUT_SECONDS="" _message_git --version >/dev/null; b=$?
        TIMEOUT_BIN="$2/none" SCAN_TIMEOUT_SECONDS=5 _message_git --version >/dev/null; c=$?
        TIMEOUT_BIN="$2" SCAN_TIMEOUT_SECONDS=5 _message_git --version >/dev/null; d=$?
        echo "$a $b $c $d"' _ "$GSG_PROJECT" "$TEST_TIMEOUT"
    assert_eq "$OUT" "1 1 1 0" "no binary, no setting and a missing binary all fail; a usable one runs git"
}

test_a_cut_block_over_text_that_is_not_gits_diff_is_scanned_whole() {
    begin forged || return 1
    verbose_repo || return 1
    { gitx diff --cached; printf '+one more line %s\n' "$MARKER"; } | verbose_message "$SANDBOX/msg-forged"
    run_message_hook forged "$SANDBOX/msg-forged"
    assert_contains "$(<"$SANDBOX/record-forged.trufflehog")" "one more line $MARKER" "a diff that git would not write is scanned"
    assert_contains "$(<"$SANDBOX/record-forged.trufflehog")" "gone $MARKER" "and the removed line with it"
    gitx diff --cached | sed 's/^+new line/+new line changed/' | verbose_message "$SANDBOX/msg-forged2"
    run_message_hook forged2 "$SANDBOX/msg-forged2"
    assert_contains "$(<"$SANDBOX/record-forged2.trufflehog")" "diff --git" "an edited diff is scanned too"
}

test_a_lone_scissors_look_alike_and_a_cut_block_without_a_diff_are_scanned() {
    begin lookalike || return 1
    local sc=' ------------------------ >8 ------------------------'
    printf 'subject\n#%s\nafter the look-alike\n#%s\n# Do not modify or remove the line above.\n# status text\n' "$sc" "$sc" >"$SANDBOX/msg-look"
    run_message_hook look "$SANDBOX/msg-look"
    assert_rc 0 "clean"
    assert_eq "$(<"$SANDBOX/record-look.trufflehog")" "== COMMIT_EDITMSG
subject
#$sc
after the look-alike
#$sc
# Do not modify or remove the line above.
# status text" "no diff follows either block, so every line is scanned"
}

test_an_empty_message_file_runs_no_scanner_and_prints_nothing() {
    begin empty || return 1
    : >"$SANDBOX/msg-empty"
    run_message_hook empty "$SANDBOX/msg-empty"
    assert_rc 0 "nothing to scan"
    assert_empty "$ERR" "no output"
    assert_eq "$(tf_runs)" 0 "no scanner ran"
}

test_a_bad_argument_list_blocks_before_any_scan() {
    begin args || return 1
    printf 'subject\n' >"$SANDBOX/msg-args"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SHARE/hooks/secret-scan" "$SANDBOX/msg-args" extra
    assert_rc 1 "two arguments"
    assert_contains "$ERR" "nothing was scanned" "failed closed"
    run_message_hook args "$SANDBOX/no-such-message"
    assert_rc 1 "a missing message file"
    assert_contains "$ERR" "nothing was scanned" "failed closed"
    run_message_hook args "$SANDBOX"
    assert_rc 1 "a directory is no message"
    assert_contains "$ERR" "nothing was scanned" "failed closed"
    assert_eq "$(tf_runs)" 0 "no scanner ran"
}

test_the_message_run_announces_the_betterleaks_files_at_head_and_the_builtin_rules_warning() {
    begin announce || return 1
    stage_file .gitleaks.toml '[extend]' 'useDefault = true' && stage_file .gitleaksignore "COMMIT_EDITMSG:generic-api-key:1" || return 1
    gitx commit -q --no-verify -m "files" || return 1
    printf 'subject\n' >"$SANDBOX/msg-announce"
    set_env STUB_GL_PREFLIGHT_RC=0
    run_message_hook announce "$SANDBOX/msg-announce"
    assert_rc 0 "clean"
    assert_contains "$ERR" "using .gitleaks.toml from HEAD" "the config is announced, a merge or a reword never ran pre-commit"
    assert_contains "$ERR" "using .gitleaksignore from HEAD" "and the fingerprints that suppress findings"
    assert_contains "$ERR" "WARNING: with .gitleaks.toml at HEAD, betterleaks does not detect its own built-in rules" "and the built-in-rules warning"
}

test_an_unusable_scanner_blocks_the_message_run_like_the_lines_run() {
    begin tool || return 1
    printf 'subject\n' >"$SANDBOX/msg-tool"
    use_stubs "TRUFFLEHOG_BIN=$SANDBOX/not-a-tool"
    run_message_hook tool "$SANDBOX/msg-tool"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "nothing was scanned" "failed closed"
}

test_a_symlink_as_gitleaks_toml_at_head_blocks_the_message_run() {
    begin cfglink || return 1
    stage_symlink other.toml .gitleaks.toml || return 1
    gitx commit -q --no-verify -m "link"
    printf 'subject\n' >"$SANDBOX/msg-link"
    run_message_hook link "$SANDBOX/msg-link"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "must be a regular file" "HEAD's betterleaks files are read with the lines run's checks"
    assert_contains "$ERR" "nothing was scanned" "failed closed"
}

# ^ invariant a stand-in setsid logs every call and forwards it; a due findings record makes the pre-commit run start doctor --recheck through it
spy_reminder_setup() {
    mkdir -p -- "$SANDBOX/spy" "$SANDBOX/home/.local/state/git-secret-guard" || return 1
    printf '#!/bin/sh\necho "$*" >>%q\nexec %q "$@"\n' "$SANDBOX/spy.log" "$TEST_SETSID" >"$SANDBOX/spy/setsid" || return 1
    chmod 755 "$SANDBOX/spy/setsid" || return 1
    printf 'not a findings record\n' >"$SANDBOX/home/.local/state/git-secret-guard/findings" || return 1
    use_stubs "SETSID_BIN=$SANDBOX/spy/setsid"
}
rechecks() { if [ -f "$SANDBOX/spy.log" ]; then grep -c 'doctor --recheck' "$SANDBOX/spy.log" || true; else echo 0; fi; }

test_the_message_run_never_starts_the_coverage_reminder() {
    begin noreminder || return 1
    [ -n "$TEST_SETSID" ] || skip_test "no setsid on this platform"
    spy_reminder_setup || return 1
    printf 'subject\n' >"$SANDBOX/msg-rem"
    stage_file f.txt one
    commit_cap "positive control"
    assert_rc 0 "pre-commit and commit-msg"
    assert_eq "$(rechecks)" 1 "the lines run started the re-check once (the control), the message run did not"
    set_env STUB_TF_FINDINGS="AWS|true|COMMIT_EDITMSG|1"
    run_message_hook rem "$SANDBOX/msg-rem"
    assert_rc 1 "a finding blocks"
    assert_eq "$(rechecks)" 1 "a blocked message run starts no re-check either"
}

test_a_hookdir_commit_msg_hook_and_the_config_hook_both_run() {
    begin hookdir || return 1
    set_env STUB_RECORD="$SANDBOX/record-hookdir"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho ran >>%q\nexit "${HOOKDIR_RC:-0}"\n' "$SANDBOX/hookdir.log" >.git/hooks/commit-msg || return 1
    chmod 755 .git/hooks/commit-msg || return 1
    stage_file src/app.txt one
    commit_cap "fix: both hooks"
    assert_rc 0 "both pass"
    assert_eq "$(<"$SANDBOX/hookdir.log")" ran "the hookdir hook ran"
    assert_eq "$(tail -n 2 "$SANDBOX/record-hookdir.trufflehog")" "== COMMIT_EDITMSG
fix: both hooks" "and the config hook scanned the message"
    set_env HOOKDIR_RC=1
    stage_file src/app.txt one two
    commit_cap "fix: the hookdir hook refuses"
    assert_rc 1 "a failing hookdir hook blocks the commit"
    assert_eq "$(grep -c '^== COMMIT_EDITMSG' "$SANDBOX/record-hookdir.trufflehog")" 2 "the config hook still scanned this message"
}

# ^ external the macOS form is "'<bash>' '<hook>'" (hook_command_text with a recorded bash); git appends the message path as the last argument
test_the_macos_command_form_hands_the_message_file_to_the_hook() {
    begin macform || return 1
    local cmd
    # ^ why a share named with a quote and a space, not the sandbox share; the escaping of the form is part of what is proven
    cp -r -- "$SHARE" "$SANDBOX/it's a share" || return 1
    # shellcheck disable=SC2016
    cmd="$(bash -c 'source "$1/lib/common.sh" && hook_command_text "$2" "$3"' _ "$GSG_PROJECT" "$SANDBOX/it's a share" "$(command -v bash)")" || return 1
    gitx config --global hook.git-secret-guard.command "$cmd" || return 1
    set_env STUB_RECORD="$SANDBOX/record-macform"
    stage_file src/app.txt one
    commit_cap "fix: through the quoted form"
    assert_rc 0 commit
    assert_eq "$(tail -n 2 "$SANDBOX/record-macform.trufflehog")" "== COMMIT_EDITMSG
fix: through the quoted form" "the message reached the hook as its argument"
}

run_file_tests
