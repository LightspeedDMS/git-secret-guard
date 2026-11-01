#!/usr/bin/env bash
# ^ external gitleaks 8.30.1 exits 1 on fatal errors too => the leak exit code is configured (--exit-code 42)
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
rows() { cat -- "$OUTD/gitleaks.rows" 2>/dev/null; }
errors() { cat -- "$OUTD/gitleaks.errors" 2>/dev/null; }
tab() { local IFS=$'\t'; printf '%s' "$*"; }

no_leak_anywhere() {
    no_leak "$1"
    assert_not_contains "$(rows)" "$1" "rows leak"
    assert_not_contains "$(errors)" "$1" "errors leak"
}

use_gitleaks_stub() {
    local tf_bin="$STUBS_DIR/trufflehog" gl_bin="$1"
    write_settings "$tf_bin" "$gl_bin" "$TEST_JQ"
}

test_clean_scan_yields_no_rows_and_no_errors() {
    prepare clean
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_rc 0 adapter
    assert_empty "$OUT$ERR" "adapter prints nothing itself"
    assert_empty "$(rows)" rows
    assert_empty "$(errors)" errors
}

test_an_unusable_timeout_binary_is_a_scan_error_and_nothing_runs() {
    prepare notimeout
    local bad
    for bad in "''" relative/timeout "$SANDBOX/missing"; do
        use_stubs "TIMEOUT_BIN=$bad"
        run_adapter gitleaks "$SCAN" "$OUTD"
        assert_rc 0 "adapter reports through the errors file"
        assert_contains "$(errors)" "timeout" "names timeout for [$bad]"
        assert_contains "$(errors)" "nothing was scanned" "says nothing was scanned"
        assert_no_file "$SANDBOX/calls-notimeout" "gitleaks was not started"
    done
}

test_invocation_pins_redaction_json_report_and_leak_exit_code() {
    prepare flags
    run_adapter gitleaks "$SCAN" "$OUTD"
    local call
    call="$(head -n 1 "$SANDBOX/calls-flags")"
    # ^ why cwd = scan dir with path ".", not an absolute path; fingerprints become "src/a.txt:rule:N", usable in a committed .gitleaksignore
    assert_contains "$call" "dir . " "dir mode on the scan tree, relative to the scan dir"
    assert_contains "$(sed -n 2p "$SANDBOX/calls-flags")" "cwd=$SCAN" "run from inside the scan dir"
    assert_contains "$call" "--redact" redact
    assert_contains "$call" "--report-format json" json
    assert_contains "$call" "--report-path $OUTD/" "report outside the scan tree"
    assert_contains "$call" "--exit-code 42" "distinct leak status"
    assert_contains "$call" "--no-banner" banner
    assert_contains "$call" "--no-color" color
}

test_config_and_ignore_file_come_from_the_private_dir_not_the_commit() {
    prepare cfg
    printf '[allowlist]\npaths = [".*"]\n' >"$SCAN/.gitleaks.toml"
    printf '*\n' >"$SCAN/.gitleaksignore"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(sed -n 2p "$SANDBOX/calls-cfg")" "gitleaks-config=$OUTD/" "explicit --config in the private dir"
    assert_contains "$(sed -n 2p "$SANDBOX/calls-cfg")" "ignore=$OUTD/" "explicit ignore path in the private dir"
    assert_contains "$(<"$SANDBOX/calls-cfg")" "gitleaks-config-line: useDefault = true" "default rules extended"
    assert_not_contains "$(<"$SANDBOX/calls-cfg")" "allowlist" "the commit's own config is not used"
}

test_a_root_gitleaksignore_in_the_commit_is_never_honored_but_still_scanned() {
    prepare mute
    printf 'src/a.txt:r1:1\n' >"$SCAN/.gitleaksignore"
    set_env STUB_RECORD="$SANDBOX/rec-mute" STUB_GL_FINDINGS="r1|.gitleaksignore.gsg-committed|1"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(<"$SANDBOX/rec-mute.gitleaks")" "== .gitleaksignore.gsg-committed" "scanned under a name gitleaks does not honor"
    if grep -qx '== .gitleaksignore' "$SANDBOX/rec-mute.gitleaks"; then fail "gitleaks saw a root .gitleaksignore"; fi
    assert_contains "$(<"$SANDBOX/rec-mute.gitleaks")" "== src/a.txt" "the rest of the tree is there"
    assert_file "$SCAN/.gitleaksignore" "the other scanner's tree is untouched"
    assert_eq "$(rows)" "$(tab gitleaks r1 finding .gitleaksignore 1)" "reported under its real name"
}

test_a_nested_gitleaksignore_needs_no_special_handling() {
    prepare nested
    mkdir -p -- "$SCAN/sub" && printf 'x:y:1\n' >"$SCAN/sub/.gitleaksignore"
    set_env STUB_LOG="$SANDBOX/calls-nested"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(sed -n 2p "$SANDBOX/calls-nested")" "cwd=$SCAN" "scanned in place"
}

test_findings_become_normalized_rows() {
    prepare findings
    set_env STUB_GL_FINDINGS="aws-access-token|src/a.txt|3;generic-api-key|src/a.txt|1"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_rc 0 adapter
    assert_eq "$(rows | LC_ALL=C sort)" "$(tab gitleaks aws-access-token finding src/a.txt 3)
$(tab gitleaks generic-api-key finding src/a.txt 1)" rows
    assert_empty "$(errors)" "leak status is not an error"
}

test_report_paths_and_fingerprints_are_repo_relative() {
    prepare relpaths
    set_env STUB_GL_FINDINGS="aws-access-token|src/a.txt|3"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_eq "$(jq -r '.[0].Fingerprint' "$OUTD/gitleaks.json")" "src/a.txt:aws-access-token:3" "fingerprint without the temp dir"
    assert_eq "$(rows)" "$(tab gitleaks aws-access-token finding src/a.txt 3)" "row"
}

test_a_relative_out_dir_is_refused() {
    prepare relout
    mkdir -p -- "$SANDBOX/rel" && cd -- "$SANDBOX/rel" || return 1
    run_adapter gitleaks "$SCAN" "relative-out"
    assert_rc 1 "adapter refuses a relative out dir"
    assert_no_file "$SANDBOX/rel/relative-out/gitleaks.json" "no scan was run"
}

test_findings_never_expose_the_secret_value() {
    prepare leak
    local marker
    marker="$(new_marker)"
    set_env STUB_MARKER="$marker" STUB_GL_FINDINGS="aws-access-token|src/a.txt|2"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(rows)" aws-access-token "row still produced"
    no_leak_anywhere "$marker"
}

test_fatal_exit_status_is_an_error_not_a_pass() {
    prepare fatal
    set_env STUB_GL_RC=1
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_empty "$(rows)" rows
    assert_contains "$(errors)" "exit 1" "error names the status"
}

test_unknown_exit_status_is_an_error() {
    prepare rc7
    set_env STUB_GL_RC=7
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(errors)" "exit 7" "error names the status"
}

test_leak_status_with_an_unparsable_report_is_an_error() {
    prepare badreport
    set_env STUB_GL_BADREPORT="garbage, not json"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_empty "$(rows)" rows
    assert_contains "$(errors)" "report" "report problem named"
}

test_leak_status_with_an_empty_report_is_an_error() {
    prepare emptyrep
    set_env STUB_GL_BADREPORT="[]"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_empty "$(rows)" rows
    assert_contains "$(errors)" "exit 42" "leak status with nothing to show is inconsistent"
}

test_clean_exit_with_findings_in_the_report_still_reports_them() {
    prepare cleanrc
    local stub="$SANDBOX/cleanrc-stub"
    cat >"$stub" <<'EOF'
#!/usr/bin/env bash
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
    if [ "${args[$i]}" = "--report-path" ]; then report="${args[$((i + 1))]}"; fi
done
printf '[{"RuleID":"r1","StartLine":2,"File":"src/a.txt"}]\n' >"$report"
exit 0
EOF
    chmod +x "$stub"
    use_gitleaks_stub "$stub"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_eq "$(rows)" "$(tab gitleaks r1 finding src/a.txt 2)" "never hide a finding behind exit 0"
}

test_clean_exit_without_a_report_is_an_error() {
    prepare cleannorep
    local stub="$SANDBOX/cleannorep-stub"
    printf '#!/usr/bin/env bash\nexit 0\n' >"$stub"
    chmod +x "$stub"
    use_gitleaks_stub "$stub"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(errors)" "report" "no report means nothing was verified"
}

test_skipped_file_warning_is_an_error_even_with_exit_0() {
    prepare skipped
    set_env STUB_GL_STDERR="8:38PM WRN skipping file: permission denied path=$SCAN/src/a.txt"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(errors)" "gitleaks: skipping file: permission denied" "the msg is shown"
    assert_not_contains "$(errors)" "path=" "structured fields are not shown"
}

test_structured_key_value_fields_of_log_lines_are_never_printed() {
    prepare fields
    local marker
    marker="$(new_marker)"
    set_env STUB_MARKER="$marker" STUB_GL_RC=1 \
        STUB_GL_STDERR="8:38PM ERR rule evaluation failed secret=$marker error=\"bad $marker\" rule=aws"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(errors)" "gitleaks: rule evaluation failed" "msg kept"
    assert_not_contains "$(errors)" "secret=" "field name dropped"
    no_leak_anywhere "$marker"
}

test_a_log_longer_than_the_cap_is_an_error_not_silently_truncated() {
    prepare biglog
    local lines
    lines="$(seq 1 5001 | sed 's/^/9:00PM INF noise /')"
    set_env STUB_GL_STDERR="$lines"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(errors)" "log exceeds 5000 lines" "fail closed instead of dropping lines"
}

test_error_log_lines_are_shown_and_other_lines_are_not() {
    prepare errlines
    local marker
    marker="$(new_marker)"
    set_env STUB_MARKER="$marker" STUB_GL_RC=1 \
        STUB_GL_STDERR="8:38PM INF info line $marker
8:38PM FTL unable to load gitleaks config, err: open /nonexistent: no such file or directory"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(errors)" "unable to load gitleaks config" "fatal line shown"
    no_leak_anywhere "$marker"
}

test_a_hung_scan_times_out_as_an_error() {
    prepare hang
    set_env STUB_GL_SLEEP=30
    use_stubs "SCAN_TIMEOUT_SECONDS=1"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_contains "$(errors)" "timed out" "timeout reported"
}

test_a_missing_binary_is_an_error_not_a_pass() {
    prepare nobin
    use_gitleaks_stub "$SANDBOX/does-not-exist"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_empty "$(rows)" rows
    assert_contains "$(errors)" "gitleaks" "error names the tool"
}

test_a_materialized_repo_config_replaces_the_default_config_passed_with_config() {
    prepare repocfg
    printf '[extend]\nuseDefault = true\n# repo-config-marker\n' >"$OUTD/repo-gitleaks.toml"
    printf '[allowlist]\npaths = [".*"]\n' >"$SCAN/.gitleaks.toml"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_rc 0 adapter
    assert_contains "$(sed -n 2p "$SANDBOX/calls-repocfg")" "gitleaks-config=$OUTD/repo-gitleaks.toml " "the HEAD copy is the config"
    assert_contains "$(<"$SANDBOX/calls-repocfg")" "gitleaks-config-line: # repo-config-marker" "its content reached gitleaks"
    assert_not_contains "$(<"$SANDBOX/calls-repocfg")" "paths = " "the commit's own .gitleaks.toml is not read"
    assert_empty "$(errors)" "no error"
}

test_a_materialized_repo_ignore_file_is_the_one_gitleaks_gets_and_the_commits_own_stays_muted() {
    prepare repoign
    printf 'src/a.txt:aws-access-token:1\n# repo-ignore-marker\n' >"$OUTD/repo-gitleaksignore"
    printf '*\n' >"$SCAN/.gitleaksignore"
    run_adapter gitleaks "$SCAN" "$OUTD"
    assert_rc 0 adapter
    local calls
    calls="$(<"$SANDBOX/calls-repoign")"
    assert_contains "$calls" "gitleaks-ignore-line: src/a.txt:aws-access-token:1" "HEAD's fingerprint list reached gitleaks"
    assert_contains "$calls" "gitleaks-ignore-line: # repo-ignore-marker" "verbatim"
    assert_not_contains "$calls" "gitleaks-ignore-line: *" "the commit's own .gitleaksignore is not honored"
}

run_file_tests
