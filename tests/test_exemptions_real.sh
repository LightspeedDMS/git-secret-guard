#!/usr/bin/env bash
# ^ external a dead proxy makes trufflehog's verification fail => "unknown" (online, a fake credential is "unverified" and hidden); see CLAUDE.md
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)

need_real_tools() {
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    use_real_tools
    set_env "${DEAD_PROXY[@]}"
}
token_line() { printf 'token = "%s"%s' "$(fake_github_token)" "${1:+ $1}"; }
# ^ external fake_github_token => trufflehog "Github (unknown)" and betterleaks "github-pat"; no other fake kind is seen by both
reported_by_trufflehog() { [[ "$ERR" =~ trufflehog\ +Github\ \(unknown\) ]]; }
reported_by_betterleaks() { [[ "$ERR" =~ betterleaks\ +github-pat\ \(finding\) ]]; }

test_real_excluded_paths_are_not_scanned_and_the_rest_is() {
    need_real_tools
    new_repo rs1 || return 1
    commit_ignore_file 'tests/fixtures/**   # synthetic keys for parser tests'
    stage_file tests/fixtures/k.txt "$(token_line)"
    stage_file src/a.txt "$(token_line)"
    commit_cap "mixed"
    assert_rc 1 "the src finding blocks"
    assert_contains "$ERR" "src/a.txt:1" "src is reported"
    assert_not_contains "$ERR" "tests/fixtures" "the excluded path is not"
    assert_contains "$ERR" "2 potential secret(s)" "one row per tool, none for the fixture"
    assert_contains "$ERR" "1 staged file(s) excluded by .secret-scan-ignore" "the exclusion is announced"
    no_leak "$(fake_github_token)"
    gitx rm -q --cached src/a.txt
    commit_cap "fixture only"
    assert_rc 0 "the fixture alone commits"
    assert_contains "$ERR" "1 staged file(s) excluded" "still announced"
}

test_real_an_exemption_counts_only_from_the_commit_after_it_is_committed() {
    need_real_tools
    new_repo rs2 || return 1
    stage_file base.txt hello && gitx commit -q --no-verify -m base
    stage_file .secret-scan-ignore 'secret/**   # fixtures'
    stage_file secret/k.txt "$(token_line)"
    commit_cap "self-exempting"
    assert_rc 1 "the finding is reported although the same commit exempts it"
    reported_by_trufflehog || fail "trufflehog row missing: ${ERR:0:300}"
    reported_by_betterleaks || fail "betterleaks row missing: ${ERR:0:300}"
    assert_contains "$ERR" "secret/k.txt:1" "real path and line"
    gitx rm -q --cached secret/k.txt
    commit_cap "the exemption on its own"
    assert_rc 0 "the ignore file alone is clean"
    stage_file secret/k.txt "$(token_line)"
    commit_cap "now covered"
    assert_rc 0 "the next commit of that path is not scanned"
    assert_contains "$ERR" "1 staged file(s) excluded by .secret-scan-ignore" "announced"
    no_leak "$(fake_github_token)"
}

test_real_the_ignore_file_is_scanned_even_when_a_pattern_or_a_catch_all_matches_it() {
    need_real_tools
    local n=0 pats
    for pats in '.secret-scan-ignore' '.*' '**'; do
        n=$((n + 1))
        new_repo "rs3-$n" || return 1
        commit_ignore_file "$pats   # matches the ignore file itself"
        printf '%s\n' "extra/**   # $(token_line)" >>.secret-scan-ignore
        gitx add .secret-scan-ignore
        commit_cap "edit"
        assert_rc 1 "[$pats] a finding inside the ignore file is reported"
        assert_contains "$ERR" ".secret-scan-ignore:2" "[$pats] real file and line"
        reported_by_betterleaks || fail "[$pats] betterleaks row missing: ${ERR:0:300}"
        no_leak "$(fake_github_token)"
    done
}

test_real_catch_all_patterns_exempt_what_git_glob_semantics_say_and_warn_every_time() {
    need_real_tools
    local n=0 spec p top_rc nested_rc
    for spec in '**|0|0' '**/*|0|0' '/**|0|0' './**|0|0' '*|0|1' '*/**|1|0'; do
        IFS='|' read -r p top_rc nested_rc <<<"$spec"
        n=$((n + 1))
        new_repo "rs5-$n" || return 1
        commit_ignore_file "$p   # legacy repository"
        stage_file top.txt "$(token_line)"
        commit_cap "top"
        assert_rc "$top_rc" "[$p] top-level finding"
        assert_contains "$ERR" "WARNING" "[$p] warns"
        gitx reset -q
        rm -f -- top.txt
        stage_file deep/er/nested.txt "$(token_line)"
        commit_cap "nested"
        assert_rc "$nested_rc" "[$p] nested finding"
        assert_contains "$ERR" "WARNING" "[$p] warns on this commit as well"
        no_leak "$(fake_github_token)"
    done
}

test_real_trufflehog_ignore_mutes_trufflehog_only() {
    need_real_tools
    new_repo rm1 || return 1
    stage_file f.txt "$(token_line '# trufflehog:ignore')"
    commit_cap "tf marker"
    assert_rc 1 "betterleaks still blocks"
    reported_by_betterleaks || fail "betterleaks row missing: ${ERR:0:300}"
    if reported_by_trufflehog; then fail "trufflehog reported a line carrying trufflehog:ignore"; fi
    no_leak "$(fake_github_token)"
}

test_real_gitleaks_allow_mutes_betterleaks_only() {
    need_real_tools
    new_repo rm2 || return 1
    stage_file f.txt "$(token_line '# gitleaks:allow')"
    commit_cap "gl marker"
    assert_rc 1 "trufflehog still blocks"
    reported_by_trufflehog || fail "trufflehog row missing: ${ERR:0:300}"
    if reported_by_betterleaks; then fail "betterleaks reported a line carrying gitleaks:allow"; fi
    no_leak "$(fake_github_token)"
}

test_real_both_markers_on_one_line_let_the_commit_succeed_in_either_order() {
    need_real_tools
    local n=0 markers
    for markers in '# trufflehog:ignore gitleaks:allow' '// gitleaks:allow trufflehog:ignore'; do
        n=$((n + 1))
        new_repo "rm3-$n" || return 1
        stage_file f.txt "$(token_line "$markers")"
        commit_cap "both markers"
        assert_rc 0 "[$markers] neither tool reports"
        assert_empty "$OUT" "stdout stays empty"
        assert_pass_line_only "$ERR" "only the pass line"
    done
}

test_real_a_marker_on_another_line_does_not_mute_the_secret() {
    need_real_tools
    new_repo rm4 || return 1
    stage_file f.txt '# trufflehog:ignore gitleaks:allow' "$(token_line)"
    commit_cap "marker above"
    assert_rc 1 "blocked"
    reported_by_trufflehog || fail "trufflehog row missing: ${ERR:0:300}"
    reported_by_betterleaks || fail "betterleaks row missing: ${ERR:0:300}"
    assert_contains "$ERR" "f.txt:2" "the secret line"
}

internal_id() { printf '%s%s' "ACMEINT" "-482915730264"; }
# ^ security generated once per run, never a literal => nothing in the tree looks like a credential; 32 random alphanumerics clear the entropy filter
# ^ external betterleaks 1.9.0 reports this shape as generic-api-key (a built-in rule); trufflehog and our aws-access-key-id rule do not match it
GENERIC_KEY="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32 || true)"
generic_key() { printf '%s' "$GENERIC_KEY"; }
builtin_line() { printf 'api_key = "%s"' "$(generic_key)"; }
commit_gitleaks_toml() {
    stage_file .gitleaks.toml "$@" || return 1
    gitx commit -q --no-verify -m "betterleaks config"
}
INTERNAL_RULE=('[[rules]]' 'id = "acme-internal"' 'description = "internal id"' "regex = '''ACMEINT-[0-9]{12}'''")

test_real_a_custom_rule_in_the_head_gitleaks_toml_fires() {
    need_real_tools
    new_repo rg1 || return 1
    stage_file f.txt "internal = $(internal_id)"
    commit_cap "without the config"
    assert_rc 0 "control: the default rules do not know this id"
    commit_gitleaks_toml '[extend]' 'useDefault = true' "${INTERNAL_RULE[@]}"
    stage_file g.txt "internal = $(internal_id)"
    commit_cap "with the config"
    assert_rc 1 "the repo's rule fires"
    assert_contains "$ERR" "acme-internal" "rule id"
    assert_contains "$ERR" "g.txt:1" "real file and line"
    assert_contains "$ERR" "using .gitleaks.toml from HEAD" "announced"
    assert_not_contains "$ERR" "WARNING" "useDefault is set"
    no_leak "$(internal_id)"
    gitx rm -q --cached g.txt
    stage_file h.txt "$(builtin_line)"
    commit_cap "default rules too"
    assert_rc 1 "[extend] useDefault keeps the built-in rules"
    assert_contains "$ERR" "generic-api-key" "built-in rule"
}

test_real_an_allowlist_in_the_head_gitleaks_toml_suppresses_a_finding() {
    need_real_tools
    new_repo rg2 || return 1
    commit_gitleaks_toml '[extend]' 'useDefault = true' '[allowlist]' 'description = "docs carry sample ids"' "paths = ['''^docs/''']"
    stage_file docs/k.txt "$(builtin_line)"
    commit_cap "allowlisted path"
    assert_rc 0 "betterleaks' own allowlist applies"
    assert_contains "$ERR" "using .gitleaks.toml from HEAD" "announced"
    stage_file src/k.txt "$(builtin_line)"
    commit_cap "same key elsewhere"
    assert_rc 1 "the allowlist is limited to its paths"
    assert_contains "$ERR" "src/k.txt:1" "reported"
    no_leak "$(generic_key)"
}

test_real_a_gitleaksignore_fingerprint_at_head_suppresses_exactly_that_finding() {
    need_real_tools
    new_repo rg3 || return 1
    stage_file .gitleaksignore '# reviewed 2026-10' '' 'src/k.txt:generic-api-key:1'
    gitx commit -q --no-verify -m "ignore file"
    stage_file src/k.txt "$(builtin_line)" "filler" "$(builtin_line)"
    stage_file src/m.txt "$(builtin_line)"
    commit_cap "three keys, one fingerprint"
    assert_rc 1 "the other two are still reported"
    assert_contains "$ERR" "2 potential secret(s)" "exactly one of three was suppressed"
    assert_contains "$ERR" "src/k.txt:3" "same file, other line"
    assert_contains "$ERR" "src/m.txt:1" "other file, same line"
    assert_not_contains "$ERR" "src/k.txt:1" "the fingerprinted finding"
    assert_contains "$ERR" "using .gitleaksignore from HEAD" "announced"
    no_leak "$(generic_key)"
}

test_real_a_repo_config_without_use_default_runs_only_its_own_rules() {
    need_real_tools
    new_repo rg4 || return 1
    commit_gitleaks_toml "${INTERNAL_RULE[@]}"
    stage_file k.txt "$(builtin_line)"
    commit_cap "key under a config without useDefault"
    assert_rc 0 "documented: the built-in generic-api-key rule is off, and trufflehog does not detect a bare key ID"
    assert_contains "$ERR" "WARNING: with .gitleaks.toml at HEAD, betterleaks does not detect its own built-in rules" "the warning says so"
    assert_contains "$ERR" "[extend] useDefault = true is missing" "and names the usual cause"
    no_leak "$(probe_secret)"
    stage_file f.txt "internal = $(internal_id)"
    commit_cap "its own rule"
    assert_rc 1 "its own rule still fires"
    assert_contains "$ERR" "acme-internal" "rule id"
    new_repo rg4b || return 1
    commit_gitleaks_toml '# a config without any rule'
    stage_file k.txt "$(builtin_line)"
    commit_cap "empty config"
    assert_rc 0 "an empty config detects nothing in betterleaks"
    assert_contains "$ERR" "WARNING" "and is announced as such"
}

# ^ external betterleaks 1.9.0 keeps the default rules for all of these (the AWS key is reported); a line scan of the TOML warned for 5 of them
USE_DEFAULT_SPELLINGS=(
    "plain|"$'[extend]\nuseDefault = true'
    "mixed-table-and-key|"$'[Extend]\nUseDefault = true'
    "upper-table-lower-key|"$'[EXTEND]\nusedefault = true'
    "inline-table|"$'extend = { useDefault = true }'
    "dotted-key|"$'extend.useDefault = true'
    "quoted-dotted-key|"$'"extend".useDefault = true'
)

test_real_every_spelling_that_keeps_the_default_rules_prints_no_warning() {
    need_real_tools
    local spec name body n=0
    for spec in "${USE_DEFAULT_SPELLINGS[@]}"; do
        name="${spec%%|*}"
        body="${spec#*|}"
        n=$((n + 1))
        new_repo "ud$n" || return 1
        commit_gitleaks_toml "$body" "${INTERNAL_RULE[@]}"
        stage_file k.txt "$(builtin_line)"
        commit_cap "key under [$name]"
        assert_rc 1 "[$name] the built-in generic-api-key rule is on, so the key blocks"
        assert_contains "$ERR" "generic-api-key" "[$name] reported by the built-in rule"
        assert_contains "$ERR" "using .gitleaks.toml from HEAD" "[$name] announced"
        assert_not_contains "$ERR" "WARNING" "[$name] no false warning"
        no_leak "$(generic_key)"
        no_leak "$(probe_secret)"
    done
}

test_real_a_use_default_setting_hidden_in_a_multi_line_string_still_warns() {
    need_real_tools
    new_repo rml || return 1
    commit_gitleaks_toml 'x = """' '[extend]' 'useDefault = true' '"""' '[[rules]]' 'id = "only-acme"' "regex = '''ACME_[A-Z0-9]{20}'''"
    stage_file k.txt "$(builtin_line)"
    commit_cap "key under a config whose useDefault text is inside a string"
    assert_rc 0 "betterleaks itself does not report the key here (rc 0, 0 findings), so nothing blocks"
    assert_contains "$ERR" "WARNING: with .gitleaks.toml at HEAD, betterleaks does not detect its own built-in rules" "the warning is printed"
    assert_contains "$ERR" "trufflehog and the AWS access key ID rule of git-secret-guard still run" "and says what remains"
    no_leak "$(generic_key)"
    no_leak "$(probe_secret)"
}

test_real_an_allowlist_that_covers_everything_also_warns_that_the_built_in_rules_are_off() {
    need_real_tools
    new_repo ral || return 1
    commit_gitleaks_toml '[extend]' 'useDefault = true' '[allowlist]' 'description = "everything"' "paths = ['''.*''']"
    stage_file k.txt "$(builtin_line)"
    commit_cap "key under an allowlist of everything"
    assert_rc 0 "documented: a global allowlist is the repository's own exemption"
    assert_contains "$ERR" "WARNING: with .gitleaks.toml at HEAD, betterleaks does not detect its own built-in rules" "the probe sees the allowlist"
    assert_contains "$ERR" "an allowlist or disabledRules" "and the message names it as a cause"
    no_leak "$(generic_key)"
    no_leak "$(probe_secret)"
}

test_real_a_config_betterleaks_cannot_load_blocks_at_the_probe_run() {
    need_real_tools
    new_repo rbad || return 1
    commit_gitleaks_toml '[[rules]]' 'description = "a rule without an id"' "regex = '''x'''"
    stage_file k.txt "$(builtin_line)"
    local before
    before="$(gitx rev-parse HEAD)"
    commit_cap "broken config"
    assert_rc 1 "fail closed"
    assert_contains "$ERR" "does not load on its own" "the pre-flight names the config"
    assert_not_contains "$ERR" "using .gitleaks.toml from HEAD" "and it is not announced as applied"
    assert_eq "$(gitx rev-parse HEAD)" "$before" "no commit was created"
    no_leak "$(generic_key)"
    no_leak "$(probe_secret)"
}

test_real_a_staged_gitleaks_config_cannot_replace_the_one_at_head() {
    need_real_tools
    new_repo rg5 || return 1
    commit_gitleaks_toml '[extend]' 'useDefault = true'
    stage_file .gitleaks.toml '[allowlist]' "paths = ['''.*''']"
    stage_file .gitleaksignore '*' 'k.txt:generic-api-key:1'
    stage_file k.txt "$(builtin_line)"
    commit_cap "mute attempt on top of a HEAD config"
    assert_rc 1 "still blocked"
    assert_contains "$ERR" "k.txt:1" "reported"
    no_leak "$(generic_key)"
}

AWS_RULE=$'[[rules]]\nid = "aws-custom"\nregex = \'\'\'AKIA[A-Z0-9]{16}\'\'\''
EXTEND_SPELLINGS=(
    "plain|$AWS_RULE"$'\n[extend]\npath = "base.toml"'
    "upper-table|$AWS_RULE"$'\n[EXTEND]\npath = "base.toml"'
    "mixed-table|$AWS_RULE"$'\n[Extend]\npath = "base.toml"'
    "upper-key|$AWS_RULE"$'\n[extend]\nPath = "base.toml"'
    "upper-both|$AWS_RULE"$'\n[Extend]\nPATH = "base.toml"'
    "mlstring-single-hides-a-table|$AWS_RULE"$'\n[extend]\nx = \'\'\'\n[other]\n\'\'\'\npath = "base.toml"'
    "mlstring-double-hides-a-table|$AWS_RULE"$'\n[extend]\nx = """\n[other]\n"""\npath = "base.toml"'
    "unicode-escaped-key|$AWS_RULE"$'\n[extend]\n"\\u0070ath" = "base.toml"'
    "unicode-escaped-table|$AWS_RULE"$'\n["\\u0065xtend"]\npath = "base.toml"'
    "root-dotted-quoted-path|"$'extend."path" = "base.toml"\n'"$AWS_RULE"
    "root-dotted-double-quoted-extend|"$'"extend".path = "base.toml"\n'"$AWS_RULE"
    "root-dotted-single-quoted-extend|"$'\'extend\'.path = "base.toml"\n'"$AWS_RULE"
    "root-dotted-capitalised|"$'Extend.Path = "base.toml"\n'"$AWS_RULE"
    "inline-table|"$'extend = { path = "base.toml" }\n'"$AWS_RULE"
    "inline-table-upper-key|"$'extend = { PATH = "base.toml" }\n'"$AWS_RULE"
    "inline-table-upper-name|"$'Extend = { path = "base.toml" }\n'"$AWS_RULE"
    "crlf|$AWS_RULE"$'\n[extend]\r\npath = "base.toml"\r'
    "tabs|$AWS_RULE"$'\n\t[\textend\t]\t\n\tpath\t=\t"base.toml"'
    "header-comment|$AWS_RULE"$'\n[extend] # base\npath = "base.toml" # x'
    "multi-line-value|$AWS_RULE"$'\n[extend]\npath = """base.toml"""'
    "parent-directory-into-the-scan-tree|$AWS_RULE"$'\n[extend]\npath = "../scan/base.toml"'
    "proc-self-cwd|$AWS_RULE"$'\n[extend]\npath = "/proc/self/cwd/base.toml"'
)

test_real_every_spelling_of_extend_path_is_refused() {
    need_real_tools
    local spec name body n=0 before
    for spec in "${EXTEND_SPELLINGS[@]}"; do
        name="${spec%%|*}"
        body="${spec#*|}"
        # ^ external macOS has no /proc; the proc-self-cwd spelling names no file there and its control run cannot mute anything
        if [ "$name" = proc-self-cwd ] && { [ "$TEST_OS" = Darwin ] || [ "$TEST_IS_WINDOWS" -eq 1 ]; }; then continue; fi
        n=$((n + 1))
        mkdir -p -- "$SANDBOX/ev$n/scan" "$SANDBOX/ev$n/ign"
        printf '[allowlist]\npaths = [%s]\n' "'''.*'''" >"$SANDBOX/ev$n/scan/base.toml"
        printf 'k = "%s"\n' "$(fake_aws_key)" >"$SANDBOX/ev$n/scan/k.txt"
        printf '%s\n' "$body" >"$SANDBOX/ev$n/cfg.toml"
        # shellcheck disable=SC2016
        run_cap bash -c 'cd -- "$1" && shift && exec "$@"' _ "$SANDBOX/ev$n/scan" "$REAL_BETTERLEAKS" dir . \
            --config "$SANDBOX/ev$n/cfg.toml" --gitleaks-ignore-path "$SANDBOX/ev$n/ign" --redact \
            --report-format json --report-path "$SANDBOX/ev$n/r.json" --exit-code 42 --no-banner --no-color
        assert_rc 0 "[$name] control: run from the scan tree the old way, betterleaks honours the base file and mutes the key"
        new_repo "rx$n" || return 1
        stage_file .gitleaks.toml "$body"
        gitx commit -q --no-verify -m cfg
        before="$(gitx rev-parse HEAD)"
        stage_file base.toml '[allowlist]' "paths = ['''.*''']"
        stage_file src/k.txt "$(builtin_line)"
        commit_cap "mute attempt"
        assert_rc 1 "[$name] blocked, not muted"
        assert_contains "$ERR" "does not load on its own" "[$name] says why"
        assert_eq "$(gitx rev-parse HEAD)" "$before" "[$name] no commit was created"
        no_leak "$(generic_key)"
    done
}

test_real_an_absolute_extend_path_to_an_existing_file_still_loads_a_documented_residual() {
    need_real_tools
    new_repo rabs || return 1
    printf '[[rules]]\nid = "from-base"\nregex = %s\n' "'''BASEMARK-[0-9]{6}'''" >"$SANDBOX/abs-base.toml"
    commit_gitleaks_toml '[extend]' 'useDefault = false' "path = \"$SANDBOX/abs-base.toml\""
    stage_file f.txt "x = BASEMARK-123456"
    commit_cap "absolute path"
    assert_rc 1 "documented residual: an absolute path to a file outside the scan tree is local, HEAD-reviewed config and loads"
    assert_contains "$ERR" "from-base" "the rule of the base file fired"
}

test_real_extend_path_cannot_make_betterleaks_honour_a_staged_file() {
    need_real_tools
    new_repo re1 || return 1
    commit_gitleaks_toml '[extend]' 'path = ".gitleaks.toml"' '[[rules]]' 'id = "aws-custom"' "regex = '''AKIA[A-Z0-9]{16}'''"
    stage_file .gitleaks.toml '[allowlist]' "paths = ['''.*''']"
    stage_file src/k.txt "$(builtin_line)"
    local before
    before="$(gitx rev-parse HEAD)"
    commit_cap "staged config muting through extend.path"
    assert_rc 1 "blocked, not silently muted"
    assert_contains "$ERR" "does not load on its own" "with the reason"
    assert_eq "$(gitx rev-parse HEAD)" "$before" "no commit was created"
    no_leak "$(generic_key)"
}

test_real_a_legitimate_extend_path_is_refused_up_front_instead_of_failing_every_scan() {
    need_real_tools
    new_repo re2 || return 1
    stage_file .gitleaks.toml '[extend]' 'path = "ci/base.toml"'
    stage_file ci/base.toml '# shared base'
    gitx commit -q --no-verify -m "legit extend.path"
    stage_file src/a.txt hello
    commit_cap "any commit"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "does not load on its own" "a clear reason"
    assert_not_contains "$ERR" "scan failed (exit 1)" "instead of an opaque scanner failure"
}

test_real_core_big_file_threshold_cannot_make_a_token_commit_silently() {
    need_real_tools
    local mode
    for mode in flag local; do
        new_repo "rb-$mode" || return 1
        stage_file src/a.txt "$(token_line)"
        if [ "$mode" = flag ]; then
            run_cap gitx -c core.bigFileThreshold=1 commit -q -m flag
        else
            gitx config core.bigFileThreshold 1
            commit_cap "local"
        fi
        assert_rc 1 "[$mode] every file counted as binary must not hide the token"
        reported_by_trufflehog || fail "[$mode] trufflehog row missing: ${ERR:0:300}"
        reported_by_betterleaks || fail "[$mode] betterleaks row missing: ${ERR:0:300}"
        no_leak "$(fake_github_token)"
    done
}

test_real_a_replace_ref_cannot_substitute_a_permissive_ignore_file() {
    need_real_tools
    new_repo rrr1 || return 1
    stage_file base.txt hello && gitx commit -q --no-verify -m base
    replace_head_with_permissive_commit .secret-scan-ignore '**   # not in the branch history' || return 1
    stage_file src/a.txt "$(token_line)"
    commit_cap "replaced HEAD"
    assert_rc 1 "the finding is still reported"
    assert_contains "$ERR" "src/a.txt:1" "real path and line"
    assert_not_contains "$ERR" "WARNING" "the substitute catch-all was never read"
    no_leak "$(fake_github_token)"
}

test_real_a_replace_ref_cannot_substitute_a_permissive_gitleaks_config() {
    need_real_tools
    new_repo rrr2 || return 1
    stage_file base.txt hello && gitx commit -q --no-verify -m base
    replace_head_with_permissive_commit .gitleaks.toml '[extend]' 'useDefault = true' '[allowlist]' "paths = ['''.*''']" || return 1
    stage_file src/k.txt "$(builtin_line)"
    commit_cap "replaced HEAD"
    assert_rc 1 "the key is still reported"
    assert_contains "$ERR" "src/k.txt:1" "real path and line"
    assert_not_contains "$ERR" "using .gitleaks.toml from HEAD" "the substitute config was never read"
    no_leak "$(generic_key)"
}

test_real_the_pre_flight_message_carries_betterleaks_message_words_and_no_fields() {
    need_real_tools
    new_repo rmw || return 1
    commit_gitleaks_toml '[extend]' 'path = "ci/base.toml"'
    stage_file src/a.txt hello
    commit_cap "blocked"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "betterleaks said: unable to load config" "the message words, without colour codes"
    assert_not_contains "$ERR" "error=" "and so does the field name"
    assert_not_contains "$ERR" $'\033' "no escape characters reach the terminal"
}

test_real_literal_pathspecs_cannot_turn_the_excludes_off() {
    need_real_tools
    local mode
    for mode in env flag; do
        new_repo "rl-$mode" || return 1
        commit_ignore_file 'docs/**   # generated'
        stage_file src/a.txt "$(token_line)"
        if [ "$mode" = env ]; then
            set_env GIT_LITERAL_PATHSPECS=1
            commit_cap "env"
        else
            run_cap gitx --literal-pathspecs commit -q -m flag
        fi
        assert_rc 1 "[$mode] the src finding is still reported"
        assert_contains "$ERR" "src/a.txt:1" "[$mode] real path and line"
        no_leak "$(fake_github_token)"
    done
}

test_real_an_old_aws_access_token_fingerprint_at_head_still_mutes_a_lone_key_id() {
    need_real_tools
    local n=0 variant
    for variant in none permissive; do
        n=$((n + 1))
        new_repo "rold$n" || return 1
        if [ "$variant" = permissive ]; then commit_gitleaks_toml '[extend]' 'useDefault = true' || return 1; fi
        stage_file .gitleaksignore 'k.txt:aws-access-token:1'
        gitx commit -q --no-verify -m "old fingerprint" || return 1
        stage_file k.txt "$(fake_aws_key)"
        commit_cap "muted by the old fingerprint"
        assert_rc 0 "[$variant] gitleaks 8.30.1 reported a lone ID as aws-access-token, so that fingerprint keeps muting it"
        stage_file m.txt "$(fake_aws_key)"
        commit_cap "other file"
        assert_rc 1 "[$variant] the fingerprint names one file and line only"
    done
}

test_real_a_crlf_aws_access_token_fingerprint_at_head_still_mutes_a_lone_key_id() {
    need_real_tools
    new_repo rcrlf || return 1
    stage_file .gitleaksignore $'k.txt:aws-access-token:1\r'
    gitx commit -q --no-verify -m "crlf fingerprint" || return 1
    stage_file k.txt "$(fake_aws_key)"
    commit_cap "muted by the CRLF fingerprint"
    assert_rc 0 "gitleaks 8.30.1 muted a lone ID with a CRLF aws-access-token entry, so does this hook"
    stage_file m.txt "$(fake_aws_key)"
    commit_cap "other file"
    assert_rc 1 "the entry names one file and line only"
}

run_file_tests
