#!/usr/bin/env bash
# ^ external a dead proxy makes trufflehog's verification fail => result "unknown" (online, a fake credential is "unverified" and hidden)
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)

need_real_tools() {
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_GITLEAKS" ] || skip_test "gitleaks not found at $REAL_GITLEAKS"
    use_real_tools
}
make_key_tree() {
    mkdir -p -- "$1/src" && printf 'x\ny\nz\naws_key = "%s"\n' "$(fake_aws_key)" >"$1/src/a.txt"
}
make_token_tree() {
    mkdir -p -- "$1/src" && printf 'x\ntoken = "%s"\n' "$(fake_github_token)" >"$1/src/a.txt"
}
GL_COMMON=(--report-format json --no-banner --no-color)

test_real_clean_diff_passes_quietly_with_both_tools() {
    need_real_tools
    new_repo realclean || return 1
    stage_file src/app.txt "hello world" "nothing secret here"
    commit_cap "clean"
    assert_rc 0 commit
    assert_empty "$OUT$ERR" "nothing is printed on success"
}

test_real_gitleaks_catches_a_fake_key_and_the_value_is_absent_from_the_output() {
    need_real_tools
    new_repo realkey || return 1
    stage_file f.txt one two "key = \"$(fake_aws_key)\""
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "gitleaks" scanner
    assert_contains "$ERR" "aws-access-token" detector
    assert_contains "$ERR" "finding" status
    assert_contains "$ERR" "f.txt:3" "real file and line"
    assert_contains "$ERR" "git commit --no-verify" "bypass hint"
    local key
    key="$(fake_aws_key)"
    no_leak "$key"
    no_leak "${key:4}"
}

test_real_trufflehog_unknown_finding_blocks_without_the_value() {
    need_real_tools
    new_repo realtf || return 1
    stage_file f.txt one "token = \"$(fake_github_token)\""
    set_env "${DEAD_PROXY[@]}"
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "trufflehog" scanner
    assert_contains "$ERR" "Github" detector
    assert_contains "$ERR" "unknown" status
    assert_contains "$ERR" "f.txt:2" "real file and line"
    local token
    token="$(fake_github_token)"
    no_leak "$token"
    no_leak "${token:4}"
}

test_real_line_numbers_survive_a_20000_line_sparse_file() {
    need_real_tools
    new_repo realbig || return 1
    yes '' | head -n 20000 >big.txt
    gitx add big.txt && gitx commit -q --no-verify -m base
    printf 'token = "%s"\n' "$(fake_github_token)" >>big.txt
    gitx add big.txt
    set_env "${DEAD_PROXY[@]}"
    commit_cap "leak"
    assert_rc 1 "blocked"
    [[ "$ERR" =~ trufflehog\ +Github\ \(unknown\)\ +big\.txt:20001 ]] || fail "trufflehog row for line 20001 missing: ${ERR:0:400}"
    [[ "$ERR" =~ gitleaks\ +github-pat\ \(finding\)\ +big\.txt:20001 ]] || fail "gitleaks row for line 20001 missing: ${ERR:0:400}"
    no_leak "$(fake_github_token)"
}

test_real_gitleaks_fingerprints_are_repo_relative() {
    need_real_tools
    local scan="$SANDBOX/scan-fp" out="$SANDBOX/out-fp"
    make_key_tree "$scan"
    run_adapter gitleaks "$scan" "$out"
    assert_eq "$(jq -r '.[0].Fingerprint' "$out/gitleaks.json")" "src/a.txt:aws-access-token:4" "fingerprint form for .gitleaksignore"
    assert_eq "$(cut -f1,2,3,4,5 "$out/gitleaks.rows")" "$(printf 'gitleaks\taws-access-token\tfinding\tsrc/a.txt\t4')" "row"
    assert_empty "$(<"$out/gitleaks.errors")" "leak status is not an error"
}

test_real_gitleaks_exit_code_semantics_8_30_1() {
    need_real_tools
    local d="$SANDBOX/gl-semantics"
    mkdir -p -- "$d/clean" "$d/leak"
    printf 'nothing\n' >"$d/clean/c.txt"
    make_key_tree "$d/leak"
    printf '[extend]\nuseDefault = true\n' >"$d/c.toml"

    run_cap "$REAL_GITLEAKS" dir "$d/clean" --config "$d/c.toml" "${GL_COMMON[@]}" --report-path "$d/r-clean.json" --exit-code 42
    assert_rc 0 "clean scan exits 0"
    assert_eq "$(<"$d/r-clean.json")" "[]" "clean scan still writes an empty array"

    run_cap "$REAL_GITLEAKS" dir "$d/leak" --config "$d/c.toml" --redact "${GL_COMMON[@]}" --report-path "$d/r-leak.json" --exit-code 42
    assert_rc 42 "leaks exit with --exit-code"
    assert_eq "$(jq length "$d/r-leak.json")" 1 "one finding in the report"
    assert_eq "$(jq -r '.[0].Secret' "$d/r-leak.json")" REDACTED "--redact hides the value in the report"

    run_cap "$REAL_GITLEAKS" dir "$d/leak" --config "$d/c.toml" --redact "${GL_COMMON[@]}" --report-path "$d/r-default.json"
    assert_rc 1 "default leak status is 1 ..."
    run_cap "$REAL_GITLEAKS" dir "$d/clean" --config "$d/missing.toml" "${GL_COMMON[@]}" --report-path "$d/r-fatal.json" --exit-code 42
    assert_rc 1 "... and a fatal error is 1 as well, hence the distinct --exit-code"
    assert_no_file "$d/r-fatal.json" "fatal error writes no report"

    run_cap "$REAL_GITLEAKS" dir "$d/does-not-exist" --config "$d/c.toml" "${GL_COMMON[@]}" --report-path "$d/r-missing.json" --exit-code 42
    assert_rc 0 "a missing target is skipped with exit 0"
    assert_contains "$ERR" "skipping" "only a WRN line says so"
}

test_real_gitleaks_fatal_config_error_shows_its_message_words_in_the_adapter_errors() {
    need_real_tools
    local scan="$SANDBOX/scan-gl-fatal" out="$SANDBOX/out-gl-fatal"
    make_key_tree "$scan"
    mkdir -p -- "$out"
    printf '[[rules]]\nid = "x"\n' >"$out/repo-gitleaks.toml"
    run_adapter gitleaks "$scan" "$out"
    assert_contains "$(<"$out/gitleaks.errors")" "gitleaks: scan failed (exit 1)" "the exit status is reported"
    assert_contains "$(<"$out/gitleaks.errors")" "gitleaks: Failed to load config" "and so are gitleaks' message words, colour codes removed"
    assert_not_contains "$(<"$out/gitleaks.errors")" "regex" "the structured error field stays hidden"
}

test_real_gitleaks_unreadable_input_exits_clean_but_the_adapter_reports_it() {
    need_real_tools
    local scan="$SANDBOX/scan-gl-unreadable" out="$SANDBOX/out-gl-unreadable"
    make_key_tree "$scan"
    printf 'hidden\n' >"$scan/src/locked.txt" && chmod 000 "$scan/src/locked.txt"
    run_adapter gitleaks "$scan" "$out"
    assert_contains "$(<"$out/gitleaks.errors")" "gitleaks: skipping file: permission denied" "unreadable input is an error"
    assert_contains "$(<"$out/gitleaks.rows")" "aws-access-token" "the readable file is still reported"
}

test_real_trufflehog_lesson_3_unreadable_input_exits_0_yet_the_adapter_errors() {
    need_real_tools
    local scan="$SANDBOX/scan-tf-unreadable" out="$SANDBOX/out-tf-unreadable"
    mkdir -p -- "$scan/src" "$out"
    printf 'hidden\n' >"$scan/src/locked.txt" && chmod 000 "$scan/src/locked.txt"
    run_cap "$REAL_TRUFFLEHOG" filesystem "$scan" --results=verified,unknown --fail --fail-on-scan-errors --no-update --json --no-color
    local direct_rc="$RC"
    if [ "$direct_rc" -ne 0 ]; then fail "trufflehog changed: exit $direct_rc on unreadable input (3.99.2 exits 0); revisit the error-log detection"; fi
    run_adapter trufflehog "$scan" "$out"
    assert_contains "$(<"$out/trufflehog.errors")" "error scanning file" "error-level log line becomes an error (direct status was $direct_rc)"
    assert_not_contains "$(<"$out/trufflehog.errors")" "locked.txt" "only the msg field, no structured path"
}

test_real_trufflehog_offline_verification_failure_is_reported_as_unknown() {
    need_real_tools
    local scan="$SANDBOX/scan-tf-unknown" out="$SANDBOX/out-tf-unknown"
    make_token_tree "$scan"
    set_env "${DEAD_PROXY[@]}"
    run_adapter trufflehog "$scan" "$out"
    assert_eq "$(<"$out/trufflehog.rows")" "$(printf 'trufflehog\tGithub\tunknown\tsrc/a.txt\t2')" "row"
    assert_empty "$(<"$out/trufflehog.errors")" "findings status is not an error"
}

test_real_trufflehog_online_fake_credential_is_unverified_and_not_reported() {
    need_real_tools
    command -v curl >/dev/null 2>&1 || skip_test "curl is not available to probe the network"
    timeout 6 curl -sS -o /dev/null https://api.github.com 2>/dev/null || skip_test "offline: verification needs the network"
    local scan="$SANDBOX/scan-tf-online" out="$SANDBOX/out-tf-online"
    make_token_tree "$scan"
    run_adapter trufflehog "$scan" "$out"
    assert_empty "$(<"$out/trufflehog.rows")" "a fake credential the vendor rejects is neither verified nor unknown"
    assert_empty "$(<"$out/trufflehog.errors")" "no error"
}

test_real_committed_gitleaks_config_and_ignore_cannot_mute_the_scan() {
    need_real_tools
    new_repo realmute || return 1
    stage_file .gitleaks.toml '[allowlist]' "paths = ['''.*''']"
    stage_file .gitleaksignore "k.txt:aws-access-token:1" "src/k.txt:aws-access-token:1" "*"
    stage_file k.txt "key = \"$(fake_aws_key)\""
    commit_cap "mute attempt"
    assert_rc 1 "still blocked"
    assert_contains "$ERR" "k.txt:1" "finding reported"
    no_leak "$(fake_aws_key)"
}

test_real_committed_gitattributes_cannot_mute_either_scanner() {
    need_real_tools
    local n=0 attrs
    for attrs in '* -diff' '*.txt binary'; do
        n=$((n + 1))
        new_repo "realattr$n" || return 1
        printf '%s\n' "$attrs" >.gitattributes
        gitx add .gitattributes
        stage_file config.txt "key = \"$(fake_aws_key)\""
        commit_cap "attribute mute attempt"
        assert_rc 1 "still blocked with [$attrs]"
        assert_contains "$ERR" "config.txt:1" "finding reported with [$attrs]"
        no_leak "$(fake_aws_key)"
    done
}

test_real_gitleaks_default_path_allowlist_hides_a_key_id_but_trufflehog_still_covers_its_own_kinds() {
    need_real_tools
    local n=0 path
    for path in node_modules/x/k.txt package-lock.json assets/logo.svg go.sum vendor/github.com/x/k.txt docs/notes.pdf; do
        n=$((n + 1))
        new_repo "realallow$n" || return 1
        stage_file "$path" "key = \"$(fake_aws_key)\""
        commit_cap "allowlisted"
        assert_rc 0 "documented limit: gitleaks' default allowlist skips $path; an AWS key ID alone is seen by gitleaks only"
    done
    new_repo realallowctl || return 1
    stage_file src/k.txt "key = \"$(fake_aws_key)\""
    commit_cap "control"
    assert_rc 1 "control: the same key at a normal path is blocked"
    new_repo realallowtf || return 1
    stage_file node_modules/x/t.txt "token = \"$(fake_github_token)\""
    set_env "${DEAD_PROXY[@]}"
    commit_cap "trufflehog kind"
    assert_rc 1 "trufflehog has no such allowlist and blocks under node_modules/"
    assert_contains "$ERR" "trufflehog" scanner
    assert_contains "$ERR" "node_modules/x/t.txt:1" "file and line"
}

test_real_utf16_and_nul_byte_files_commit_unscanned_a_documented_limit() {
    need_real_tools
    command -v iconv >/dev/null 2>&1 || skip_test "iconv is not available"
    new_repo realutf16 || return 1
    printf 'key = "%s"\n' "$(fake_aws_key)" | iconv -f UTF-8 -t UTF-16LE >windows.txt
    printf 'key = "%s"\n\000' "$(fake_aws_key)" >nul.txt
    printf 'key = "%s"\n' "$(fake_aws_key)" | iconv -f UTF-8 -t UTF-16 >bom.txt
    gitx add windows.txt nul.txt bom.txt
    commit_cap "binary-looking text"
    assert_rc 0 "documented limit: git treats UTF-16 and NUL-containing text as binary, so nothing is scanned"
    assert_empty "$OUT$ERR" "and nothing is printed"
}

test_real_service_environment_scans_with_both_real_tools() {
    need_real_tools
    new_repo realsvc || return 1
    service_prepare
    service_env
    stage_file a.txt "plain text"
    run_cap env -i "${SVC_ENV[@]}" git commit -q -m clean
    assert_rc 0 "clean commit in the service environment"
    stage_file b.txt "key = \"$(fake_aws_key)\""
    run_cap env -i "${SVC_ENV[@]}" git commit -q -m leak
    assert_rc 1 "finding blocks in the service environment"
    assert_contains "$ERR" "b.txt:1" "decided by the finding"
    assert_not_contains "$ERR" "not executable" "no environment error"
    no_leak "$(fake_aws_key)"
}

run_file_tests
