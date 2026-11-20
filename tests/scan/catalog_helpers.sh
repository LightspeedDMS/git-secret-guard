# shellcheck shell=bash
# ^ see doc:docs/bypass-detection-scenarios.md; helpers of the files pinning catalog rows, test_bypass_catalog.sh and test_bypass_formats_real.sh
# ^ security GSG_CATALOG_REPORT names a TSV the tests append to; hook stderr only, it never holds a value (no_leak checks each test)

DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)
CATALOG_REPORT="${GSG_CATALOG_REPORT:-}"
CATALOG_HEADER='ID\tExpected\tActual\tVerdict\tUTC\tHost\tOS\tGit\tCommand\tHook output\n'
# ^ hazard two catalog files run in parallel; noclobber lets only one of them create the report with its header
if [ -n "$CATALOG_REPORT" ] && [ ! -e "$CATALOG_REPORT" ]; then
    # shellcheck disable=SC2059
    (set -C && printf "$CATALOG_HEADER" >"$CATALOG_REPORT") 2>/dev/null || [ -e "$CATALOG_REPORT" ] || exit 2
elif [ -n "$CATALOG_REPORT" ] && [ ! -s "$CATALOG_REPORT" ]; then
    # shellcheck disable=SC2059
    printf "$CATALOG_HEADER" >"$CATALOG_REPORT" || exit 2
fi

need_real_tools() {
    local extra="${1:-}"
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    use_real_tools "$extra"
    set_env "${DEAD_PROXY[@]}"
}

# ^ security fragments and per-call random parts => no credential-looking literal; test:test_the_project_tree_holds_no_credential_looking_literals
fake_gitlab_token() { printf '%s%s' "glpat""-" "$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 20 || true)"; }
aws_doc_key_id() { printf '%s%s' "AKI""A" "IOSFODNN7EXAMPLE"; }
aws_doc_secret() { printf '%s%s' "wJalrXUtnFEMI/K7MDENG/bPxRfiCY" "EXAMPLEKEY"; }
token_line() { printf 'token = "%s"' "$(fake_github_token)"; }

catalog_os() {
    local pretty=""
    if [ "$TEST_OS" = Darwin ]; then
        printf 'macOS %s (%s)' "$(sw_vers -productVersion 2>/dev/null)" "$(uname -m)"
        return 0
    fi
    if [ -r /etc/os-release ]; then pretty="$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"')"; fi
    printf '%s (%s)' "${pretty:-$(uname -sr)}" "$(uname -srm)"
}

# ^ invariant classifies the last run_cap; Blocked = a scan ran and stopped it, Blocked-unscanned = it stopped before scanning, Allowed = exit 0
catalog_actual() {
    if [ "$RC" -eq 0 ]; then
        printf 'Allowed'
    elif [[ $ERR == *"nothing was scanned"* ]]; then
        printf 'Blocked-unscanned'
    elif [[ $ERR == *"git-secret-guard:"* ]]; then
        printf 'Blocked'
    else
        printf 'Error'
    fi
}

# ^ invariant one TSV row per call when GSG_CATALOG_REPORT is set; nothing otherwise; the verdict compares the catalog's Expected with Actual
catalog() {
    local id="$1" expected="$2" cmd="$3" actual verdict text
    actual="$(catalog_actual)"
    case "$expected:$actual" in
        Block:Blocked | Allow:Allowed | Detect:Blocked | FailClosed:Blocked-unscanned) verdict=PASS ;;
        *:Blocked-unscanned) verdict=ERROR ;;
        Detect:Allowed) verdict=PENDING-SEC ;;
        Gap:* | Record:*) verdict=RECORDED ;;
        *:Error) verdict=ERROR ;;
        *) verdict=FAIL ;;
    esac
    [ -n "$CATALOG_REPORT" ] || return 0
    text="${ERR//$'\t'/ }"
    text="${text//$'\n'/ | }"
    text="${text//[^[:print:]]/?}"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$expected" "$actual" "$verdict" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        "$(uname -n)" "$(catalog_os)" "$("$GIT" --version)" "$cmd" "${text:0:600}" >>"$CATALOG_REPORT"
}

assert_blocked() {
    assert_rc 1 "$1 blocked"
    assert_not_contains "$ERR" "nothing was scanned" "$1 the hook scanned (a setup block proves nothing)"
    assert_contains "$ERR" "potential secret(s)" "$1 by a finding"
}
assert_blocked_unscanned() {
    assert_rc 1 "$1 blocked"
    assert_contains "$ERR" "nothing was scanned" "$1 failed closed"
}
assert_hook_never_ran() {
    assert_rc 0 "$1 commits"
    assert_not_contains "$ERR" "git-secret-guard" "$1 without any hook output"
}
restore_hook_files() {
    cp -- "$GSG_PROJECT/hooks/secret-scan" "$SHARE/hooks/secret-scan" || return 1
    chmod 755 -- "$SHARE/hooks/secret-scan" || return 1
    cp -- "$GSG_PROJECT/lib/scan/betterleaks-rule.toml" "$SHARE/lib/scan/betterleaks-rule.toml"
}
