#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

SCAN="" OUTD=""
prepare() {
    SCAN="$SANDBOX/scan-$1"
    OUTD="$SANDBOX/out-$1"
    make_scan_tree "$SCAN"
    mkdir -p -- "$OUTD"
    set_env STUB_LOG="$SANDBOX/calls-$1" STUB_MARKER="$(new_marker)"
}
rows() { cat -- "$OUTD/trufflehog.rows" 2>/dev/null; }
errors() { cat -- "$OUTD/trufflehog.errors" 2>/dev/null; }
tab() { local IFS=$'\t'; printf '%s' "$*"; }

no_leak_anywhere() {
    no_leak "$1"
    assert_not_contains "$(rows)" "$1" "rows leak"
    assert_not_contains "$(errors)" "$1" "errors leak"
}

test_clean_scan_yields_no_rows_and_no_errors() {
    prepare clean
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_rc 0 adapter
    assert_empty "$OUT$ERR" "adapter prints nothing itself"
    assert_empty "$(rows)" rows
    assert_empty "$(errors)" errors
}

test_invocation_uses_the_pinned_flags_on_the_scan_dir() {
    prepare flags
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_eq "$(head -n 1 "$SANDBOX/calls-flags")" \
        "trufflehog filesystem $SCAN --results=verified,unknown --fail --fail-on-scan-errors --no-update --json --no-color" flags
}

test_verified_and_unknown_findings_become_normalized_rows() {
    prepare findings
    set_env STUB_TF_FINDINGS="AWS|true|src/a.txt|3;Github|false|src/a.txt|1"
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_rc 0 adapter
    assert_eq "$(rows | LC_ALL=C sort)" "$(tab trufflehog AWS verified src/a.txt 3)
$(tab trufflehog Github unknown src/a.txt 1)" rows
    assert_empty "$(errors)" "finding exit 183 is not an error"
}

test_findings_never_expose_the_secret_value() {
    prepare leak
    local marker
    marker="$(new_marker)"
    set_env STUB_MARKER="$marker" STUB_TF_FINDINGS="AWS|true|src/a.txt|2"
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_contains "$(rows)" AWS "row still produced"
    no_leak_anywhere "$marker"
}

test_an_unusable_timeout_binary_is_a_scan_error_and_nothing_runs() {
    prepare notimeout
    local bad
    for bad in "''" relative/timeout "$SANDBOX/missing"; do
        use_stubs "TIMEOUT_BIN=$bad"
        run_adapter trufflehog "$SCAN" "$OUTD"
        assert_rc 0 "adapter reports through the errors file"
        assert_contains "$(errors)" "timeout" "names timeout for [$bad]"
        assert_contains "$(errors)" "nothing was scanned" "says nothing was scanned"
        assert_no_file "$SANDBOX/calls-notimeout" "trufflehog was not started"
    done
}

test_exit_183_without_results_is_an_error() {
    prepare e183
    set_env STUB_TF_RC=183
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_empty "$(rows)" rows
    assert_contains "$(errors)" "exit 183" "error names the status"
}

test_unexpected_exit_status_is_an_error() {
    prepare rc2
    set_env STUB_TF_RC=2
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_contains "$(errors)" "exit 2" "error names the status"
}

test_error_level_log_with_exit_0_is_an_error_showing_only_msg() {
    prepare errlog
    local marker
    marker="$(new_marker)"
    set_env STUB_MARKER="$marker" STUB_TF_ERRLOG="error scanning file"
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_contains "$(errors)" "error scanning file" "msg shown"
    assert_not_contains "$(errors)" "verify.invalid" "structured url field"
    no_leak_anywhere "$marker"
}

test_non_json_stderr_is_not_an_error_and_is_not_echoed() {
    prepare rawerr
    local marker
    marker="$(new_marker)"
    set_env STUB_MARKER="$marker" STUB_TF_RAWERR="noise $marker not json"
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_empty "$(errors)" "plain stderr text is ignored"
    no_leak_anywhere "$marker"
}

test_unparsable_results_are_an_error() {
    prepare badjson
    local stub="$SANDBOX/badjson-stub"
    printf '#!/usr/bin/env bash\necho "this is not json"\nexit 183\n' >"$stub"
    chmod +x "$stub"
    write_settings "$stub" "$STUBS_DIR/gitleaks" "$TEST_JQ"
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_empty "$(rows)" rows
    assert_contains "$(errors)" "parse" "parse failure reported"
}

test_a_hung_scan_times_out_as_an_error() {
    prepare hang
    set_env STUB_TF_SLEEP=30
    use_stubs "SCAN_TIMEOUT_SECONDS=1"
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_contains "$(errors)" "timed out" "timeout reported"
}

test_a_tool_that_exits_0_without_scanning_is_an_error() {
    prepare silent
    write_settings "$TEST_TRUE" "$STUBS_DIR/gitleaks" "$TEST_JQ"
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_empty "$(rows)" rows
    assert_contains "$(errors)" "did not report a completed scan" "silence is not a clean scan"
}

test_a_completion_line_with_zero_chunks_is_an_error_for_a_non_empty_tree() {
    prepare zerochunks
    set_env STUB_TF_CHUNKS=0
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_contains "$(errors)" "did not report a completed scan" "nothing was actually scanned"
}

test_a_completion_line_with_chunks_counts_as_a_completed_scan() {
    prepare chunks
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_empty "$(errors)" "the stand-in reports its chunks like the real tool"
}

test_a_missing_binary_is_an_error_not_a_pass() {
    prepare nobin
    write_settings "$SANDBOX/does-not-exist" "$STUBS_DIR/gitleaks" "$TEST_JQ"
    run_adapter trufflehog "$SCAN" "$OUTD"
    assert_empty "$(rows)" rows
    assert_contains "$(errors)" "trufflehog" "error names the tool"
}

run_file_tests
