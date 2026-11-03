#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

CALLS="" MARKER=""
begin() {
    new_repo "$1" || return 1
    CALLS="$SANDBOX/calls-$1"
    MARKER="$(new_marker)"
    set_env STUB_LOG="$CALLS" STUB_MARKER="$MARKER"
}
count_calls() { local n=0; if [ -f "$CALLS" ]; then n="$(grep -c "^$1 " "$CALLS")"; fi; printf '%s' "$n"; }
tf_runs() { count_calls trufflehog; }
gl_runs() { count_calls gitleaks; }
has_head() { gitx rev-parse -q --verify HEAD >/dev/null 2>&1; }
assert_no_commit() { if has_head; then fail "a commit was created"; fi; }
workdirs() { find "$SANDBOX/tmp" -maxdepth 1 -name 'git-secret-guard.*' 2>/dev/null; }

test_clean_commit_prints_one_summary_line_and_runs_both_tools() {
    begin clean || return 1
    stage_file src/app.txt one two three
    commit_cap "clean"
    assert_rc 0 commit
    assert_empty "$OUT" "stdout stays empty"
    [[ $ERR =~ $PASS_LINE_RE ]] || fail "stderr is not exactly the pass line: [$ERR]"
    assert_eq "${BASH_REMATCH[1]}" 1 "one file"
    assert_eq "${BASH_REMATCH[2]}" 3 "three added lines"
    assert_eq "${BASH_REMATCH[3]}" "trufflehog 1.2.3, gitleaks 4.5.6" "versions come from the settings"
    assert_eq "$(wc -l <<<"$ERR" | tr -d ' ')" 1 "exactly one line"
    assert_eq "$(tf_runs)" 1 "trufflehog ran once"
    assert_eq "$(gl_runs)" 1 "gitleaks ran once"
    has_head || fail "commit was not created"
    assert_empty "$(workdirs)" "private temp dir removed"
}

test_scan_tree_has_real_paths_and_real_line_numbers() {
    begin tree || return 1
    set_env STUB_RECORD="$SANDBOX/record-tree"
    stage_file src/app.txt a b c && gitx commit -q --no-verify -m base
    stage_file src/app.txt a X c
    commit_cap "edit"
    assert_rc 0 commit
    local tool
    for tool in trufflehog gitleaks; do
        assert_eq "$(<"$SANDBOX/record-tree.$tool")" "== src/app.txt

X" "$tool saw added line 2 at line 2 of src/app.txt, nothing else"
    done
}

test_private_work_dir_is_mode_700_during_the_scan() {
    begin mode || return 1
    stage_file f.txt hello
    commit_cap "mode"
    assert_contains "$(<"$CALLS")" "workdir-mode=700" "work dir is private"
}

test_trufflehog_verified_finding_blocks_and_names_everything_but_the_value() {
    begin tfv || return 1
    stage_file src/app.txt one two three
    set_env STUB_TF_FINDINGS="AWS|true|src/app.txt|2"
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "trufflehog" scanner
    assert_contains "$ERR" "AWS" detector
    assert_contains "$ERR" "verified" status
    assert_contains "$ERR" "src/app.txt:2" "file and line"
    assert_contains "$ERR" "git commit --no-verify" "bypass hint"
    no_leak "$MARKER"
    assert_no_commit
}

test_trufflehog_unknown_finding_blocks() {
    begin tfu || return 1
    stage_file src/app.txt one two three
    set_env STUB_TF_FINDINGS="Github|false|src/app.txt|3"
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "unknown" status
    assert_contains "$ERR" "src/app.txt:3" "file and line"
    no_leak "$MARKER"
}

test_gitleaks_finding_blocks_and_names_everything_but_the_value() {
    begin gl || return 1
    stage_file src/app.txt one two three
    set_env STUB_GL_FINDINGS="aws-access-token|src/app.txt|1"
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "gitleaks" scanner
    assert_contains "$ERR" "aws-access-token" detector
    assert_contains "$ERR" "finding" status
    assert_contains "$ERR" "src/app.txt:1" "file and line"
    assert_contains "$ERR" "git commit --no-verify" "bypass hint"
    no_leak "$MARKER"
    assert_no_commit
}

test_findings_from_both_tools_are_merged_into_one_report() {
    begin both || return 1
    stage_file a.txt one two
    stage_file b.txt three four
    set_env STUB_TF_FINDINGS="AWS|true|a.txt|1" STUB_GL_FINDINGS="generic-api-key|b.txt|2"
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "a.txt:1" "trufflehog row"
    assert_contains "$ERR" "b.txt:2" "gitleaks row"
    assert_contains "$ERR" "2 potential" "count"
    no_leak "$MARKER"
}

test_trufflehog_unexpected_exit_status_blocks_with_the_error() {
    begin tfrc || return 1
    stage_file a.txt one
    set_env STUB_TF_RC=2
    commit_cap "err"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "trufflehog" tool
    assert_contains "$ERR" "exit 2" status
    assert_no_commit
}

test_gitleaks_unexpected_exit_status_blocks_with_the_error() {
    begin glrc || return 1
    stage_file a.txt one
    set_env STUB_GL_RC=1
    commit_cap "err"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "gitleaks" tool
    assert_contains "$ERR" "exit 1" status
}

test_trufflehog_error_log_with_exit_0_blocks_showing_only_msg() {
    begin tflog || return 1
    stage_file a.txt one
    set_env STUB_TF_ERRLOG="error scanning file"
    commit_cap "err"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "error scanning file" "msg shown"
    assert_not_contains "$ERR" "verify.invalid" "structured field not shown"
    no_leak "$MARKER"
}

test_one_tool_failing_still_reports_the_other_tools_findings() {
    begin mixed || return 1
    stage_file a.txt one
    set_env STUB_TF_RC=2 STUB_GL_FINDINGS="r1|a.txt|1"
    commit_cap "mixed"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "exit 2" "error shown"
    assert_contains "$ERR" "a.txt:1" "finding shown"
}

# ^ invariant a 300-character path component passes update-index --cacheinfo and fails on disk => the awk write fails (ENAMETOOLONG) like a full disk
test_an_extraction_write_failure_blocks_with_a_message_about_extraction_and_keeps_the_awk_line() {
    local long blob
    begin awkwrite || return 1
    long="$(printf 'n%.0s' $(seq 1 300)).txt"
    printf '%s\n' one >seed.txt && blob="$(gitx hash-object -w seed.txt)" || return 1
    gitx update-index --add --cacheinfo "100644,$blob,$long" || return 1
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "extracting the added lines" "the message says the extraction failed"
    assert_contains "$ERR" "nothing was scanned" "and that nothing was scanned"
    assert_not_contains "$ERR" "could not read the staged diff" "it no longer claims that reading the diff failed"
    if ! grep -q -i 'awk\|too long\|cannot\|can.t\|fatal' <<<"$ERR"; then fail "no awk error line in: ${ERR:0:300}"; fi
    if LC_ALL=C grep -q '[^ -~]' <<<"$ERR"; then fail "raw control or non-ASCII bytes reached stderr"; fi
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
    assert_no_commit
    assert_empty "$(workdirs)" "the work directory is gone"
}

test_missing_trufflehog_blocks_naming_the_tool_and_scanning_nothing() {
    begin notf || return 1
    write_settings "$SANDBOX/missing/trufflehog" "$STUBS_DIR/gitleaks" "$TEST_JQ"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "trufflehog" "names the tool"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
    assert_eq "$(gl_runs)" 0 "gitleaks not started either"
    assert_no_commit
}

test_missing_gitleaks_blocks_naming_the_tool() {
    begin nogl || return 1
    write_settings "$STUBS_DIR/trufflehog" "$SANDBOX/missing/gitleaks" "$TEST_JQ"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "gitleaks" "names the tool"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
    assert_eq "$(tf_runs)" 0 "trufflehog not started either"
}

test_missing_jq_blocks_naming_the_tool() {
    begin nojq || return 1
    write_settings "$STUBS_DIR/trufflehog" "$STUBS_DIR/gitleaks" "$SANDBOX/missing/jq"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "jq" "names the tool"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
}

test_a_trufflehog_that_exits_0_silently_blocks_like_a_missing_gitleaks_report() {
    begin silenttf || return 1
    write_settings "$TEST_TRUE" "$STUBS_DIR/gitleaks" "$TEST_JQ"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "did not report a completed scan" "says why"
    assert_no_commit
}

test_non_executable_tool_blocks() {
    begin noexec || return 1
    local copy="$SANDBOX/noexec-trufflehog"
    cp -- "$STUBS_DIR/trufflehog" "$copy" && chmod 644 "$copy"
    write_settings "$copy" "$STUBS_DIR/gitleaks" "$TEST_JQ"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "not executable" "says why"
}

test_every_missing_tool_is_listed() {
    begin allmissing || return 1
    write_settings "$SANDBOX/m/t" "$SANDBOX/m/g" "$SANDBOX/m/j"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "trufflehog" t
    assert_contains "$ERR" "gitleaks" g
    assert_contains "$ERR" "jq" j
}

test_relative_tool_path_is_refused_no_path_lookup() {
    begin relpath || return 1
    write_settings "trufflehog" "$STUBS_DIR/gitleaks" "$TEST_JQ"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "absolute" "relative names are not looked up on PATH"
}

test_environment_cannot_supply_a_tool_the_settings_omit() {
    begin envoverride || return 1
    printf 'GITLEAKS_BIN=%q\nJQ_BIN=%q\n' "$STUBS_DIR/gitleaks" "$TEST_JQ" >"$SHARE/settings"
    set_env TRUFFLEHOG_BIN="$STUBS_DIR/trufflehog"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "trufflehog" "the env var did not fill the gap"
    assert_eq "$(tf_runs)" 0 "env-supplied tool never ran"
}

test_missing_settings_file_blocks() {
    begin nosettings || return 1
    rm -f -- "$SHARE/settings"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "settings" "names the problem"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
}

test_empty_commit_starts_no_scanner_and_succeeds() {
    begin empty || return 1
    commit_cap "empty" --allow-empty
    assert_rc 0 commit
    assert_eq "$ERR" "git-secret-guard: no added lines to scan" "one line says nothing was there to scan"
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
    has_head || fail "commit was not created"
}

test_deletion_only_commit_starts_no_scanner_and_succeeds() {
    begin del || return 1
    stage_file gone.txt one two && gitx commit -q --no-verify -m base
    gitx rm -q -- gone.txt
    commit_cap "delete"
    assert_rc 0 commit
    assert_eq "$ERR" "git-secret-guard: no added lines to scan" "one line says nothing was there to scan"
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
}

test_binary_content_is_never_passed_to_the_scanners() {
    begin bin || return 1
    set_env STUB_RECORD="$SANDBOX/record-bin"
    printf '\000\001%s\000\377' "$MARKER" >blob.bin
    gitx add blob.bin
    stage_file text.txt plain
    commit_cap "bin"
    assert_rc 0 commit
    local tool
    for tool in trufflehog gitleaks; do
        assert_not_contains "$(<"$SANDBOX/record-bin.$tool")" "$MARKER" "$tool: binary payload"
        assert_not_contains "$(<"$SANDBOX/record-bin.$tool")" "blob.bin" "$tool: binary file name"
        assert_contains "$(<"$SANDBOX/record-bin.$tool")" "text.txt" "$tool: text file still scanned"
    done
}

drop_versions() {
    grep -v '_VERSION=' "$SHARE/settings" >"$SHARE/settings.new" && mv -- "$SHARE/settings.new" "$SHARE/settings"
}

test_the_pass_line_counts_files_and_added_lines_from_the_extraction() {
    begin counts || return 1
    stage_file a.txt one ''
    stage_file deep/b.txt x y z
    commit_cap "two files"
    assert_rc 0 commit
    [[ $ERR =~ $PASS_LINE_RE ]] || fail "not the pass line: [$ERR]"
    assert_eq "${BASH_REMATCH[1]}" 2 "two files"
    assert_eq "${BASH_REMATCH[2]}" 5 "five added lines, the blank one included"
    assert_not_contains "$ERR" "a.txt" "no path in the line"
}

test_settings_without_versions_print_the_line_without_versions() {
    begin nover || return 1
    drop_versions || return 1
    stage_file a.txt one
    commit_cap "old settings"
    assert_rc 0 "an older install still commits"
    assert_pass_line_only "$ERR" "still the pass line"
    assert_contains "$ERR" "(trufflehog, gitleaks)" "tool names without versions"
}

test_a_version_that_is_not_digits_and_dots_is_dropped_from_the_line() {
    begin badver || return 1
    use_stubs "TRUFFLEHOG_VERSION='9.9 FORGED all clear'"
    stage_file a.txt one
    commit_cap "forged"
    assert_rc 0 commit
    assert_pass_line_only "$ERR" "still one pass line"
    assert_contains "$ERR" "(trufflehog, gitleaks 4.5.6)" "only the sane version is shown"
    assert_not_contains "$ERR" "FORGED" "the odd text never reaches the terminal"
}

test_an_inherited_version_variable_cannot_fill_a_version_the_settings_omit() {
    begin inherit || return 1
    drop_versions || return 1
    set_env TRUFFLEHOG_VERSION=7.7.7 GITLEAKS_VERSION=8.8.8
    stage_file a.txt one
    commit_cap "inherited"
    assert_rc 0 commit
    assert_contains "$ERR" "(trufflehog, gitleaks)" "no inherited version"
}

test_findings_and_blocks_print_no_pass_line() {
    begin nopass || return 1
    stage_file a.txt one two
    set_env STUB_TF_FINDINGS="AWS|true|a.txt|2"
    commit_cap "finding"
    assert_rc 1 "blocked by the finding"
    assert_not_contains "$ERR" "no findings" "no pass line with a finding"
    assert_not_contains "$ERR" "scanned " "no pass line with a finding"
    set_env STUB_TF_FINDINGS=
    use_stubs "GITLEAKS_BIN=/nonexistent/gitleaks"
    commit_cap "blocked"
    assert_rc 1 "blocked by the missing tool"
    assert_contains "$ERR" "nothing was scanned" "the existing block text"
    assert_not_contains "$ERR" "no findings" "no pass line on a block"
}

# ^ external the hook resolves awk through PATH; the wrapper runs the real awk and afterwards damages the counts file it was told to write
test_a_missing_or_garbage_counts_file_blocks_and_never_reports_zero() {
    begin badcounts || return 1
    local real_awk mode
    real_awk="$(command -v awk)" || return 1
    mkdir -p -- "$SANDBOX/fakeawk" || return 1
    # shellcheck disable=SC2016
    printf '%s\n' '#!/bin/bash' "\"$real_awk\" \"\$@\"" 'rc=$?' \
        'if [ -n "${GSG_EXTRACT_COUNTS:-}" ]; then' \
        '  case "${GSG_TEST_COUNTS_MODE:-}" in missing) rm -f -- "$GSG_EXTRACT_COUNTS" ;; garbage) printf "x y\n" >"$GSG_EXTRACT_COUNTS" ;; esac' \
        'fi' 'exit $rc' >"$SANDBOX/fakeawk/awk" && chmod 755 "$SANDBOX/fakeawk/awk" || return 1
    stage_file a.txt one two
    for mode in missing garbage; do
        set_env PATH="$SANDBOX/fakeawk:$REAL_HOME/.local/bin:$TEST_BASE_PATH" GSG_TEST_COUNTS_MODE="$mode"
        commit_cap "damaged counts $mode"
        assert_rc 1 "$mode: blocked"
        assert_contains "$ERR" "nothing was scanned" "$mode: says nothing was scanned"
        assert_not_contains "$ERR" "no added lines to scan" "$mode: never the empty-commit message"
        assert_not_contains "$ERR" "scanned 0" "$mode: never zeros"
        assert_eq "$(tf_runs)$(gl_runs)" 00 "$mode: no scanner started"
    done
    assert_no_commit
}

test_binary_only_commit_starts_no_scanner() {
    begin binonly || return 1
    printf '\000\001%s\000\377' "$MARKER" >blob.bin
    gitx add blob.bin
    commit_cap "bin"
    assert_rc 0 commit
    assert_eq "$ERR" "git-secret-guard: no added lines to scan" "one line says nothing was there to scan"
    assert_eq "$(tf_runs)$(gl_runs)" 00 "nothing textual to scan"
}

test_no_verify_skips_the_scan_even_with_a_finding() {
    begin noverify || return 1
    stage_file a.txt one
    set_env STUB_TF_FINDINGS="AWS|true|a.txt|1"
    commit_cap "bypass" --no-verify
    assert_rc 0 commit
    assert_eq "$(tf_runs)$(gl_runs)" 00 "scan did not run"
    has_head || fail "commit was not created"
}

test_config_parameter_disables_the_scan_but_repo_hooks_still_run() {
    begin exempt || return 1
    printf '#!/bin/sh\ntouch "%s/repo-hook-ran"\n' "$SANDBOX" >.git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    stage_file a.txt one
    set_env STUB_TF_FINDINGS="AWS|true|a.txt|1" GIT_CONFIG_PARAMETERS="'hook.$HOOK_NAME.enabled'='false'"
    commit_cap "automation"
    assert_rc 0 commit
    assert_eq "$(tf_runs)$(gl_runs)" 00 "scan did not run"
    assert_file "$SANDBOX/repo-hook-ran" "the repo's own hook still ran"
}

test_repo_local_config_can_disable_or_replace_the_hook() {
    begin localoverride || return 1
    set_env STUB_TF_FINDINGS="AWS|true|a.txt|1"
    stage_file a.txt one
    gitx config --local "hook.$HOOK_NAME.enabled" false
    commit_cap "disabled"
    assert_rc 0 "documented limit: a repo-local enabled=false stops the scan"
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
    gitx config --local --unset "hook.$HOOK_NAME.enabled"
    gitx config --local "hook.$HOOK_NAME.command" true
    stage_file b.txt two
    commit_cap "replaced"
    assert_rc 0 "documented limit: a repo-local .command replaces the scan"
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
}

test_missing_scan_script_fails_the_commit() {
    begin noscript || return 1
    gitx config --global "hook.$HOOK_NAME.command" "$SANDBOX/no/such/secret-scan"
    stage_file a.txt one
    commit_cap "x"
    [ "$RC" -ne 0 ] || fail "commit succeeded without the scan script"
    assert_no_commit
}

test_non_executable_scan_script_fails_the_commit() {
    begin noexecscript || return 1
    cp -- "$SHARE/hooks/secret-scan" "$SANDBOX/secret-scan-noexec" && chmod 644 "$SANDBOX/secret-scan-noexec"
    gitx config --global "hook.$HOOK_NAME.command" "$SANDBOX/secret-scan-noexec"
    stage_file a.txt one
    commit_cap "x"
    [ "$RC" -ne 0 ] || fail "commit succeeded without an executable scan script"
}

test_both_tools_run_in_parallel() {
    begin par || return 1
    set_env STUB_TF_SLEEP=2 STUB_GL_SLEEP=2
    stage_file a.txt one
    local t0 t1
    t0="$(date +%s%N)"
    commit_cap "par"
    t1="$(date +%s%N)"
    assert_rc 0 commit
    [ $(((t1 - t0) / 1000000)) -lt 3600 ] || fail "took $(((t1 - t0) / 1000000)) ms; the tools ran one after the other"
}

test_hook_outside_a_repository_blocks_instead_of_passing() {
    begin norepo || return 1
    mkdir -p -- "$SANDBOX/plain" && cd -- "$SANDBOX/plain" || return 1
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SHARE/hooks/secret-scan"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "cannot read .secret-scan-ignore at HEAD" "names the problem: git cannot read HEAD here"
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
}

test_hook_blocks_when_neither_tmpdir_nor_home_is_set() {
    begin nohome || return 1
    run_cap env -i PATH="$TEST_BASE_PATH" "$SHARE/hooks/secret-scan"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "TMPDIR nor HOME" "names the problem"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
}

test_hook_falls_back_to_home_tmp_when_tmpdir_is_unset() {
    begin homedir || return 1
    stage_file a.txt one
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/local/bin:/usr/bin:/bin" GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig" \
        GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$CALLS" "$GIT" commit -q -m home
    assert_rc 0 commit
    assert_contains "$(<"$CALLS")" "workdir-mode=700" "scan ran with a work dir under HOME/.tmp"
    assert_eq "$(find "$SANDBOX/home/.tmp" -maxdepth 1 -name 'git-secret-guard.*' | wc -l)" 0 "work dir removed"
}

test_a_scan_wrapper_failing_internally_blocks_the_commit() {
    begin wrapfail || return 1
    use_stubs "scan_trufflehog() { return 7; }"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "trufflehog: scan wrapper failed internally (exit 7)" "status shown"
    use_stubs "scan_gitleaks() { return 9; }"
    commit_cap "y"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "gitleaks: scan wrapper failed internally (exit 9)" "status shown"
    assert_no_commit
}

SIGDUR=""
# ^ security match on this sandbox's temp path and a per-test sleep duration, never on shared paths => stubs of a concurrent run or sandbox are not counted
scanner_processes() { pgrep -f -- "$SANDBOX/tmp|sleep $SIGDUR" | wc -l; }

signal_test() {
    begin "$1" || return 1
    SIGDUR="6.$RANDOM"
    set_env STUB_TF_SLEEP="$SIGDUR" STUB_GL_SLEEP="$SIGDUR" "${@:3}"
    stage_file a.txt one
    # ^ external a background job starts with SIGINT ignored; env --default-signal restores it as in a terminal Ctrl-C
    env --default-signal=INT,TERM -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$GIT" commit -q -m sig >/dev/null 2>&1 &
    local cpid=$! tries=0
    while { [ "$(tf_runs)" -lt 1 ] || [ "$(gl_runs)" -lt 1 ]; } && [ "$tries" -lt 150 ]; do sleep 0.1; tries=$((tries + 1)); done
    assert_eq "$(find "$SANDBOX/tmp" -maxdepth 1 -name 'git-secret-guard.*' | wc -l)" 1 "work dir exists during the scan"
    [ "$(scanner_processes)" -ge 2 ] || fail "sanity: scanners are not running before the signal"
    pkill "-$2" -f "$SHARE/hooks/secret-scan"
    wait "$cpid"
    assert_empty "$(workdirs)" "work dir removed right after $2"
    assert_eq "$(scanner_processes)" 0 "no scanner, timeout or sleep process survives $2"
    sleep 2
    assert_empty "$(workdirs)" "work dir stays gone 2 s after $2"
    assert_eq "$(scanner_processes)" 0 "still no survivor 2 s after $2"
}

test_term_signal_stops_the_scanners_and_removes_the_private_temp_dir() { signal_test term TERM; }
test_int_signal_stops_the_scanners_and_removes_the_private_temp_dir() { signal_test int INT; }
test_a_scanner_that_ignores_term_is_killed_before_the_temp_dir_is_removed() { signal_test stubborn TERM STUB_TF_STUBBORN=1; }

# ^ external macOS has no /proc; ps -p reports the state letter on both, Z (zombie) counts as gone
proc_alive() {
    local st
    st="$(ps -p "$1" -o stat= 2>/dev/null)" || return 1
    st="${st//[[:space:]]/}"
    [ -n "$st" ] && [ "${st:0:1}" != Z ]
}

test_scanner_process_detection_ignores_look_alikes_from_other_sandboxes() {
    begin decoy || return 1
    SIGDUR="6.$RANDOM"
    (exec -a "$STUBS_DIR/trufflehog-decoy" sleep 25) &
    local dpid=$!
    sleep 0.3
    assert_eq "$(scanner_processes)" 0 "a process outside this sandbox is not a scanner of this test"
    kill "$dpid"
    wait "$dpid" 2>/dev/null
    return 0
}

test_a_timed_out_scanner_leaves_no_grandchild_behind() {
    begin grandchild || return 1
    use_stubs "SCAN_TIMEOUT_SECONDS=1"
    set_env STUB_TF_GRANDCHILD="$SANDBOX/grandchild.pid"
    stage_file a.txt one
    commit_cap "timeout"
    assert_rc 1 "a timed-out scanner blocks"
    assert_contains "$ERR" "timed out" "says why"
    local gpid tries=0
    gpid="$(<"$SANDBOX/grandchild.pid")"
    while proc_alive "$gpid" && [ "$tries" -lt 30 ]; do sleep 0.1; tries=$((tries + 1)); done
    if proc_alive "$gpid"; then
        fail "grandchild $gpid of the timed-out scanner is still running"
        kill "$gpid"
    fi
}

test_the_hook_blocks_when_setsid_or_timeout_is_not_a_usable_absolute_path() {
    begin badprocs || return 1
    stage_file a.txt one
    local key bad label
    for label in setsid timeout; do
        key="${label^^}_BIN"
        for bad in "" relative/path "$SANDBOX/missing" "$SANDBOX"; do
            use_stubs "$key=$(printf '%q' "$bad")"
            commit_cap "x"
            assert_rc 1 "$key=[$bad] blocks"
            assert_contains "$ERR" "$label " "names the tool for $key=[$bad]"
            assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
            assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started for $key=[$bad]"
        done
    done
    assert_no_commit
}

test_the_hook_takes_setsid_and_timeout_from_settings_never_from_PATH() {
    begin fromsettings || return 1
    mkdir -p -- "$SANDBOX/poison" "$SANDBOX/wrap"
    local tool real
    for tool in setsid timeout; do
        real="$TEST_SETSID"
        if [ "$tool" = timeout ]; then real="$TEST_TIMEOUT"; fi
        printf '#!/bin/bash\necho PATH-USED >>"%s/poison.log"\nexit 99\n' "$SANDBOX" >"$SANDBOX/poison/$tool"
        # shellcheck disable=SC2016
        printf '#!/bin/bash\necho "$0" >>"%s/wrap.log"\nexec %s "$@"\n' "$SANDBOX" "$real" >"$SANDBOX/wrap/$tool"
        chmod +x "$SANDBOX/poison/$tool" "$SANDBOX/wrap/$tool"
    done
    use_stubs "SETSID_BIN=$SANDBOX/wrap/setsid
TIMEOUT_BIN=$SANDBOX/wrap/timeout"
    set_env PATH="$SANDBOX/poison:$TEST_BASE_PATH"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 0 "scan completes with PATH poisoned"
    assert_no_file "$SANDBOX/poison.log" "nothing resolved setsid/timeout through PATH"
    assert_contains "$(sort -u "$SANDBOX/wrap.log")" "$SANDBOX/wrap/setsid" "configured setsid used"
    assert_contains "$(sort -u "$SANDBOX/wrap.log")" "$SANDBOX/wrap/timeout" "configured timeout used"
    assert_eq "$(tf_runs)$(gl_runs)" 11 "both scanners ran"
}

test_a_signal_before_the_runner_has_its_own_group_does_not_wait_for_the_scan() {
    begin earlysig || return 1
    mkdir -p -- "$SANDBOX/fakebin"
    printf '#!/bin/bash\nsleep 1.5\nexec %s "$@"\n' "$TEST_SETSID" >"$SANDBOX/fakebin/setsid"
    chmod +x "$SANDBOX/fakebin/setsid"
    use_stubs "SETSID_BIN=$SANDBOX/fakebin/setsid"
    set_env STUB_TF_SLEEP=4 STUB_GL_SLEEP=4
    stage_file a.txt one
    env --default-signal=INT,TERM -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$GIT" commit -q -m early >/dev/null 2>&1 &
    local cpid=$! tries=0
    while [ -z "$(find "$SANDBOX/tmp" -path '*/scan/a.txt' 2>/dev/null)" ] && [ "$tries" -lt 100 ]; do sleep 0.05; tries=$((tries + 1)); done
    sleep 0.3
    local t0 t1
    t0="$(date +%s%N)"
    pkill -TERM -f "$SHARE/hooks/secret-scan"
    wait "$cpid"
    t1="$(date +%s%N)"
    [ $(((t1 - t0) / 1000000)) -lt 2500 ] || fail "cleanup took $(((t1 - t0) / 1000000)) ms; it waited for a runner that had no group yet"
    assert_empty "$(workdirs)" "work dir removed"
    sleep 3
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started after the hook was gone"
}

# ^ external a GUI git client on macOS starts with /usr/bin:/bin; /bin/bash 3.2 and the BSD tools come first, the recorded bash and GNU directory must win
test_a_git_client_with_the_system_bash_first_on_PATH_still_scans() {
    [ -n "$TEST_BASH" ] || skip_test "the recorded bash and GNU directory exist on macOS only"
    begin guipath || return 1
    stage_file a.txt one two
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig" \
        GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$CALLS" "$GIT" commit -q -m gui
    assert_rc 0 "commit under a GUI-style PATH"
    assert_empty "$OUT" "stdout stays empty"
    assert_pass_line_only "$ERR" "only the pass line is printed"
    assert_eq "$(tf_runs)$(gl_runs)" 11 "both scanners ran"
    assert_empty "$(workdirs)" "private temp dir removed"
}

# ^ external macOS /bin/bash is 3.2; any other host with a bash >= 4.4 there has nothing to test here
old_system_bash() {
    [ -x /bin/bash ] && /bin/bash -c '[ "${BASH_VERSINFO[0]}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 4 ]; }'
}

test_a_gnu_directory_in_the_settings_that_is_relative_or_missing_blocks_the_commit() {
    [ -n "$TEST_BASH" ] || skip_test "GNUBIN_DIR exists on macOS only"
    local bad
    begin badgnu || return 1
    for bad in "relative/gnubin" "$SANDBOX/no-such-gnubin"; do
        use_stubs "GNUBIN_DIR=$bad"
        stage_file a.txt one
        commit_cap "x"
        assert_rc 1 "GNUBIN_DIR=[$bad] blocks"
        assert_contains "$ERR" "GNUBIN_DIR" "names the setting for [$bad]"
        assert_contains "$ERR" "nothing was scanned" "says nothing was scanned for [$bad]"
        assert_no_commit
        assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started for [$bad]"
    done
}

test_the_hook_blocks_under_a_bash_older_than_4_4_instead_of_scanning() {
    old_system_bash || skip_test "/bin/bash is 4.4 or newer on this host"
    begin oldbash || return 1
    stage_file a.txt one
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" STUB_LOG="$CALLS" /bin/bash "$SHARE/hooks/secret-scan"
    assert_rc 1 "the hook under bash 3.2"
    assert_contains "$ERR" "bash 4.4" "names the bash it needs"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
}

test_a_commit_through_a_bare_hook_command_under_the_system_bash_is_blocked() {
    old_system_bash || skip_test "/bin/bash is 4.4 or newer on this host"
    begin barecmd || return 1
    gitx config --global "hook.$HOOK_NAME.command" "$SHARE/hooks/secret-scan" || return 1
    stage_file a.txt one
    run_cap env -i HOME="$SANDBOX/home" PATH="/usr/bin:/bin" TMPDIR="$SANDBOX/tmp" GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig" \
        GIT_CONFIG_NOSYSTEM=1 STUB_LOG="$CALLS" "$GIT" commit -q -m bare
    assert_rc 1 "the commit is blocked"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
    assert_no_commit
    assert_eq "$(tf_runs)$(gl_runs)" 00 "no scanner started"
}

run_file_tests
