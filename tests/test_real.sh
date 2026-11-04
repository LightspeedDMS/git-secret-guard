#!/usr/bin/env bash
# ^ external a dead proxy makes trufflehog's verification fail => result "unknown" (online, a fake credential is "unverified" and hidden)
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)

need_real_tools() {
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
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
    assert_empty "$OUT" "stdout stays empty"
    assert_pass_line_only "$ERR" "only the pass line is printed on success"
}

test_real_betterleaks_catches_a_fake_key_and_the_value_is_absent_from_the_output() {
    need_real_tools
    new_repo realkey || return 1
    stage_file f.txt one two "key = \"$(fake_aws_key)\""
    commit_cap "leak"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "betterleaks" scanner
    assert_contains "$ERR" "aws-access-key-id" "detector: our rule, since 1.9.0 reports a key ID only with its secret nearby"
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
    [[ "$ERR" =~ betterleaks\ +github-pat\ \(finding\)\ +big\.txt:20001 ]] || fail "betterleaks row for line 20001 missing: ${ERR:0:400}"
    no_leak "$(fake_github_token)"
}

test_real_betterleaks_fingerprints_are_repo_relative() {
    need_real_tools
    local scan="$SANDBOX/scan-fp" out="$SANDBOX/out-fp"
    make_key_tree "$scan"
    run_adapter betterleaks "$scan" "$out"
    assert_eq "$(jq -r '.[0].Fingerprint' "$out/betterleaks.json")" "src/a.txt:aws-access-key-id:4" "fingerprint form for .gitleaksignore"
    assert_eq "$(cut -f1,2,3,4,5 "$out/betterleaks.rows")" "$(printf 'betterleaks\taws-access-key-id\tfinding\tsrc/a.txt\t4')" "row"
    assert_empty "$(<"$out/betterleaks.errors")" "leak status is not an error"
}

test_real_betterleaks_exit_code_semantics_1_9_0() {
    need_real_tools
    local d="$SANDBOX/gl-semantics"
    mkdir -p -- "$d/clean" "$d/leak"
    printf 'nothing\n' >"$d/clean/c.txt"
    make_key_tree "$d/leak"
    printf '[extend]\nuseDefault = true\n' >"$d/c.toml"

    run_cap "$REAL_BETTERLEAKS" dir "$d/clean" --config "$d/c.toml" "${GL_COMMON[@]}" --report-path "$d/r-clean.json" --exit-code 42
    assert_rc 0 "clean scan exits 0"
    assert_eq "$(<"$d/r-clean.json")" "[]" "clean scan still writes an empty array"

    run_cap "$REAL_BETTERLEAKS" dir "$d/leak" --config "$d/c.toml" --redact "${GL_COMMON[@]}" --report-path "$d/r-leak.json" --exit-code 42
    assert_rc 42 "leaks exit with --exit-code"
    assert_eq "$(jq length "$d/r-leak.json")" 1 "one finding in the report"
    assert_eq "$(jq -r '.[0].Secret' "$d/r-leak.json")" REDACTED "--redact hides the value in the report"

    run_cap "$REAL_BETTERLEAKS" dir "$d/leak" --config "$d/c.toml" --redact "${GL_COMMON[@]}" --report-path "$d/r-default.json"
    assert_rc 1 "default leak status is 1 ..."
    run_cap "$REAL_BETTERLEAKS" dir "$d/clean" --config "$d/missing.toml" "${GL_COMMON[@]}" --report-path "$d/r-fatal.json" --exit-code 42
    assert_rc 1 "... and a fatal error is 1 as well, hence the distinct --exit-code"
    assert_no_file "$d/r-fatal.json" "fatal error writes no report"

    run_cap "$REAL_BETTERLEAKS" dir "$d/does-not-exist" --config "$d/c.toml" "${GL_COMMON[@]}" --report-path "$d/r-missing.json" --exit-code 42
    assert_rc 0 "a missing target is skipped with exit 0"
    assert_contains "$ERR" "skipping" "only a WRN line says so"
}

test_real_betterleaks_fatal_config_error_shows_its_message_words_in_the_adapter_errors() {
    need_real_tools
    local scan="$SANDBOX/scan-gl-fatal" out="$SANDBOX/out-gl-fatal"
    make_key_tree "$scan"
    mkdir -p -- "$out"
    printf '[[rules]]\nid = "x"\n' >"$out/repo-gitleaks.toml"
    run_adapter betterleaks "$scan" "$out"
    assert_contains "$(<"$out/betterleaks.errors")" "betterleaks: scan failed (exit 1)" "the exit status is reported"
    assert_contains "$(<"$out/betterleaks.errors")" "betterleaks: unable to load config" "and so are betterleaks' message words"
    assert_not_contains "$(<"$out/betterleaks.errors")" $'\e' "colour codes are removed (FTL lines are coloured even with --no-color)"
    assert_not_contains "$(<"$out/betterleaks.errors")" "regex=" "no structured field is printed"
}

test_real_betterleaks_unreadable_input_exits_clean_but_the_adapter_reports_it() {
    need_real_tools
    local scan="$SANDBOX/scan-gl-unreadable" out="$SANDBOX/out-gl-unreadable"
    make_key_tree "$scan"
    printf 'hidden\n' >"$scan/src/locked.txt" && chmod 000 "$scan/src/locked.txt"
    run_adapter betterleaks "$scan" "$out"
    assert_contains "$(<"$out/betterleaks.errors")" "betterleaks: skipping file: permission denied" "unreadable input is an error"
    assert_contains "$(<"$out/betterleaks.rows")" "aws-access-key-id" "the readable file is still reported"
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

test_real_betterleaks_default_path_allowlist_hides_a_key_id_but_trufflehog_still_covers_its_own_kinds() {
    need_real_tools
    local n=0 path
    for path in node_modules/x/k.txt package-lock.json assets/logo.svg go.sum vendor/github.com/x/k.txt docs/notes.pdf; do
        n=$((n + 1))
        new_repo "realallow$n" || return 1
        stage_file "$path" "key = \"$(fake_aws_key)\""
        commit_cap "allowlisted"
        assert_rc 0 "documented limit: betterleaks' default allowlist skips $path; an AWS key ID alone is seen by betterleaks only"
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
    printf 'key = "%s"\n\000' "$(fake_aws_key)" >nulbyte.txt
    printf 'key = "%s"\n' "$(fake_aws_key)" | iconv -f UTF-8 -t UTF-16 >bom.txt
    gitx add windows.txt nulbyte.txt bom.txt
    commit_cap "binary-looking text"
    assert_rc 0 "documented limit: git treats UTF-16 and NUL-containing text as binary, so nothing is scanned"
    assert_empty "$OUT" "nothing on stdout"
    assert_eq "$ERR" "git-secret-guard: no added lines to scan" "git sees a binary file, so the hook says there was nothing to scan"
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

# ^ invariant bl_direct DIR REPORT ARGS runs the real betterleaks on DIR with default rules, a dead proxy and the adapter's flags; sets RC
bl_direct() {
    local dir="$1" report="$2"
    shift 2
    printf '[extend]\nuseDefault = true\n' >"$SANDBOX/bl-default.toml"
    run_cap env -C "$dir" "${DEAD_PROXY[@]}" "$REAL_BETTERLEAKS" dir . --config "$SANDBOX/bl-default.toml" --redact "${GL_COMMON[@]}" \
        --report-path "$report" --exit-code 42 "$@"
}

test_real_betterleaks_version_text_and_validation_off_by_default_1_9_0() {
    need_real_tools
    local d="$SANDBOX/bl-pin"
    run_cap "$REAL_BETTERLEAKS" --version
    assert_eq "$OUT" "betterleaks version 1.9.0" "the version text tools_version_matches reads"
    mkdir -p -- "$d" && printf 'token = "%s"\n' "$(fake_github_token)" >"$d/f.txt"
    bl_direct "$d" "$d.json"
    assert_rc 42 "a finding"
    assert_eq "$(jq -r '.[0].ValidationStatus' "$d.json")" null "validation is not attempted unless asked for"
    bl_direct "$d" "$d.json" --validation
    assert_eq "$(jq -r '.[0].ValidationStatus' "$d.json")" error "with --validation the dead proxy turns it into an error: the flag is what reaches the network"
}

test_real_aws_access_token_needs_the_secret_key_within_5_lines_so_our_rule_covers_a_lone_id() {
    need_real_tools
    local lone="$SANDBOX/bl-lone" pair="$SANDBOX/bl-pair" secret key
    secret="$(fake_aws_secret)" key="$(fake_aws_key)"
    mkdir -p -- "$lone" "$pair" && printf '%s\n' "$key" >"$lone/f.txt" && printf '%s\nsecret_access_key = "%s"\n' "$key" "$secret" >"$pair/f.txt" || return 1
    bl_direct "$lone" "$lone.json"
    assert_rc 0 "betterleaks alone reports a lone key ID as nothing (gitleaks 8.30.1 did)"
    bl_direct "$pair" "$pair.json"
    assert_rc 42 "a key with its secret within 5 lines is reported"
    assert_eq "$(jq -r '.[0].RuleID' "$pair.json")" aws-access-token "by the built-in composite rule"
    run_adapter betterleaks "$lone" "$SANDBOX/out-lone"
    assert_eq "$(cut -f1,2,3,4,5 "$SANDBOX/out-lone/betterleaks.rows")" "$(printf 'betterleaks\taws-access-key-id\tfinding\tf.txt\t1')" "our rule reports the lone ID"
    run_adapter betterleaks "$pair" "$SANDBOX/out-pair"
    assert_eq "$(cut -f1,2,3,4,5 "$SANDBOX/out-pair/betterleaks.rows")" "$(printf 'betterleaks\taws-access-token\tfinding\tf.txt\t1')" "a pair is reported once, as aws-access-token"
    no_leak "$key"
    no_leak "$secret"
    assert_not_contains "$(<"$SANDBOX/out-pair/betterleaks.rows")$(<"$SANDBOX/out-pair/betterleaks.errors")" "$secret" "the adapter never writes the secret"
}

# ^ invariant report_where REPORT prints "file:line" of every finding, sorted and comma separated
report_where() { jq -r '[.[] | "\(.File):\(.StartLine)"] | sort | join(",")' "$1"; }

test_real_betterleaks_reads_root_ignore_files_and_configs_on_its_own_1_9_0() {
    need_real_tools
    local d="$SANDBOX/bl-root" ign="$SANDBOX/bl-ign" allow cfg
    allow="$(printf '[extend]\nuseDefault = true\n[allowlist]\npaths = [%sf\\.txt%s]\n' "'''" "'''")"
    mkdir -p -- "$d/sub" "$ign" && printf 'token = "%s"\n' "$(fake_github_token)" | tee "$d/f.txt" >"$d/sub/f.txt" || return 1
    bl_direct "$d" "$d.json"
    assert_eq "$(report_where "$d.json")" "f.txt:1,sub/f.txt:1" "baseline: both files are reported"
    printf 'f.txt:github-pat:1\n' >"$d/.gitleaksignore" || return 1
    bl_direct "$d" "$d.json" --gitleaks-ignore-path "$ign"
    assert_eq "$(report_where "$d.json")" "sub/f.txt:1" "a root .gitleaksignore mutes its fingerprint whatever --gitleaks-ignore-path says"
    mv -- "$d/.gitleaksignore" "$d/.betterleaksignore" || return 1
    bl_direct "$d" "$d.json" --gitleaks-ignore-path "$ign"
    assert_eq "$(report_where "$d.json")" "sub/f.txt:1" "and so does a root .betterleaksignore"
    rm -f -- "$d/.betterleaksignore" && printf 'sub/f.txt:github-pat:1\n' >"$d/sub/.gitleaksignore" || return 1
    bl_direct "$d" "$d.json"
    assert_eq "$(report_where "$d.json")" "f.txt:1,sub/f.txt:1" "a nested ignore file is not read"
    rm -f -- "$d/sub/.gitleaksignore" && printf 'f.txt:github-pat:1\n' >"$ign/.gitleaksignore" || return 1
    bl_direct "$d" "$d.json" --gitleaks-ignore-path "$ign"
    assert_eq "$(report_where "$d.json")" "sub/f.txt:1" "--gitleaks-ignore-path DIR reads DIR/.gitleaksignore"
    for cfg in .gitleaks.toml .betterleaks.toml; do
        printf '%s\n' "$allow" >"$d/$cfg" || return 1
        run_cap env -C "$d" "$REAL_BETTERLEAKS" dir . --redact "${GL_COMMON[@]}" --report-path "$d.json" --exit-code 42
        assert_rc 0 "a root $cfg is loaded when there is no --config"
        bl_direct "$d" "$d.json"
        assert_rc 42 "an explicit --config wins over a root $cfg"
        rm -f -- "$d/$cfg" || return 1
    done
}

test_real_betterleaks_inline_markers_and_config_precedence_1_9_0() {
    need_real_tools
    local d="$SANDBOX/bl-marks" tok allow_all
    tok="$(fake_github_token)"
    allow_all="$(printf '[extend]\nuseDefault = true\n[allowlist]\npaths = [%s(?s).*%s]\n' "'''" "'''")"
    mkdir -p -- "$d" && printf 'a = "%s" # gitleaks:allow\nb = "%s" # betterleaks:allow\nc = "%s"\n' "$tok" "$tok" "$tok" >"$d/f.txt" || return 1
    bl_direct "$d" "$d.json"
    assert_eq "$(report_where "$d.json")" "f.txt:3" "both markers mute their own line only"
    bl_direct "$d" "$d.json" --ignore-gitleaks-allow
    assert_eq "$(report_where "$d.json")" "f.txt:1,f.txt:2,f.txt:3" "--ignore-gitleaks-allow turns both off"
    printf '%s\n' "$allow_all" >"$SANDBOX/bl-env.toml" || return 1
    run_cap env -C "$d" BETTERLEAKS_CONFIG="$SANDBOX/bl-env.toml" GITLEAKS_CONFIG="$SANDBOX/bl-env.toml" BETTERLEAKS_CONFIG_TOML="$allow_all" \
        "$REAL_BETTERLEAKS" dir . --config "$SANDBOX/bl-default.toml" --redact "${GL_COMMON[@]}" --report-path "$d.json" --exit-code 42
    assert_rc 42 "an environment config never beats --config"
}

# ^ invariant repo_with_config NAME VARIANT builds a fresh repo whose HEAD holds .gitleaks.toml as VARIANT says
# ^ invariant none = no config at HEAD; permissive = built-in rules extended; builtins_off = an allowlist over every path and no [extend]
repo_with_config() {
    new_repo "$1" || return 1
    case "$2" in
        none) return 0 ;;
        permissive) stage_file .gitleaks.toml '[extend]' 'useDefault = true' ;;
        builtins_off) stage_file .gitleaks.toml '[allowlist]' "paths = ['''(?s).*''']" ;;
        *) return 1 ;;
    esac
    gitx commit -q --no-verify -m config
}

test_real_a_lone_aws_key_id_blocks_with_and_without_a_repo_config() {
    need_real_tools
    local n=0 variant
    for variant in none permissive builtins_off; do
        n=$((n + 1))
        repo_with_config "reallone$n" "$variant" || return 1
        stage_file k.txt "$(fake_aws_key)"
        commit_cap "lone id"
        assert_rc 1 "blocked with repo config [$variant]: a repository cannot switch our rule off"
        assert_contains "$ERR" "aws-access-key-id" "the rule of ours [$variant]"
        assert_contains "$ERR" "k.txt:1" "file and line [$variant]"
        no_leak "$(fake_aws_key)"
    done
}

test_real_a_key_pair_blocks_once_as_aws_access_token() {
    need_real_tools
    local secret
    secret="$(fake_aws_secret)"
    new_repo realpair || return 1
    stage_file k.txt "$(fake_aws_key)" "secret_access_key = \"$secret\""
    commit_cap "pair"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "aws-access-token" "the built-in composite rule"
    assert_not_contains "$ERR" "aws-access-key-id" "one finding for the pair, not two"
    no_leak "$(fake_aws_key)"
    no_leak "$secret"
}

test_real_an_inline_marker_and_a_head_fingerprint_mute_the_lone_aws_key_id() {
    need_real_tools
    local n=0 variant
    for variant in none permissive; do
        n=$((n + 1))
        repo_with_config "realmuteA$n" "$variant" || return 1
        stage_file k.txt "id = \"$(fake_aws_key)\" # gitleaks:allow"
        commit_cap "marker"
        assert_rc 0 "the inline marker mutes it [$variant]"
        repo_with_config "realmuteB$n" "$variant" || return 1
        stage_file .gitleaksignore 'k.txt:aws-access-key-id:1' && gitx commit -q --no-verify -m ignore || return 1
        stage_file k.txt "$(fake_aws_key)"
        commit_cap "fingerprint"
        assert_rc 0 "the HEAD .gitleaksignore fingerprint mutes it [$variant]"
        stage_file m.txt "$(fake_aws_key)"
        commit_cap "other line"
        assert_rc 1 "a lone ID in a file the fingerprint does not name still blocks [$variant]"
    done
}

test_real_our_aws_rule_matches_what_gitleaks_aws_access_token_did() {
    need_real_tools
    local d="$SANDBOX/bl-idshapes" out="$SANDBOX/out-idshapes"
    mkdir -p -- "$d" || return 1
    printf '%s%s%s\n' "AKI" "A" "IOSFODNN7EXAMPLE" >"$d/example.txt" || return 1
    printf '%s%s\n' "AKIA" "AAAAAAAAAAAAAAAA" >"$d/low.txt" || return 1
    printf '%s%s\n' "A3TX" "Q7XK2MWB4HZ5NR3T" >"$d/a3t.txt" || return 1
    printf '%s\n' "$(fake_aws_key)" >"$d/akia.txt" || return 1
    run_adapter betterleaks "$d" "$out"
    assert_eq "$(cut -f2,4,5 "$out/betterleaks.rows" | LC_ALL=C sort)" "$(printf 'aws-access-key-id\ta3t.txt\t1\naws-access-key-id\takia.txt\t1')" \
        "the documented example ID and a low-entropy placeholder pass, an A3T ID and a normal lone ID are reported"
    assert_empty "$(<"$out/betterleaks.errors")" "no error"
}

test_real_a_lone_aws_key_id_under_a_skipped_path_passes_with_and_without_a_repo_config() {
    need_real_tools
    local n=0 variant
    for variant in none permissive; do
        n=$((n + 1))
        repo_with_config "realskip$n" "$variant" || return 1
        stage_file node_modules/x/k.txt "$(fake_aws_key)"
        commit_cap "skipped path"
        assert_rc 0 "[$variant] node_modules/ is covered by the default skip list for our rule in both cases"
        no_leak "$(fake_aws_key)"
    done
}

run_file_tests
