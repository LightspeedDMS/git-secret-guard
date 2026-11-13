#!/usr/bin/env bash
# ^ see doc:docs/bypass-detection-scenarios.md; each test pins the hook's current answer to one catalog row, gaps included
# ^ external a dead proxy makes trufflehog's verification fail => "unknown" (online, a fake credential is "unverified" and hidden); see docs/scan.md
# ^ security GSG_CATALOG_REPORT names a TSV the tests append to; hook stderr only, it never holds a value (no_leak checks each test)
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

DEAD_PROXY=(HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9)
CATALOG_REPORT="${GSG_CATALOG_REPORT:-}"
CATALOG_HEADER='ID\tExpected\tActual\tVerdict\tUTC\tHost\tOS\tGit\tCommand\tHook output\n'
if [ -n "$CATALOG_REPORT" ] && [ ! -s "$CATALOG_REPORT" ]; then
    # shellcheck disable=SC2059
    printf "$CATALOG_HEADER" >"$CATALOG_REPORT" || exit 2
fi

# ^ external Git for Windows has no /bin/jq and the hook needs TASKKILL_BIN there; install writes both (a jq -b wrapper), tests/lib.sh writes neither
win_extra_settings() {
    local jq tk
    jq="$(type -P jq.exe || type -P jq)" || skip_test "jq not found on PATH (winget install jqlang.jq)"
    tk="$(type -P taskkill.exe || type -P taskkill)" || skip_test "taskkill not found on PATH"
    printf '#!/usr/bin/env bash\nexec %q -b "$@"\n' "$jq" >"$SANDBOX/jq-b" || return 1
    chmod 755 -- "$SANDBOX/jq-b" || return 1
    TEST_JQ="$SANDBOX/jq-b"
    printf 'TASKKILL_BIN=%q' "$tk"
}

WIN_EXTRA=""
real_tools_with() { use_real_tools "${WIN_EXTRA}${WIN_EXTRA:+${1:+$'\n'}}${1:-}"; }

need_real_tools() {
    local extra="${1:-}"
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    case "$(uname -s)" in
        MINGW64_NT-*)
            win_extra_settings >"$SANDBOX/win-extra" || return 1
            TEST_JQ="$SANDBOX/jq-b"
            WIN_EXTRA="$(<"$SANDBOX/win-extra")"
            ;;
    esac
    real_tools_with "$extra"
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
    cp -- "$GSG_PROJECT/lib/betterleaks-rule.toml" "$SHARE/lib/betterleaks-rule.toml"
}
commit_token_on_branch() {
    gitx checkout -q -b "$1" || return 1
    stage_file k.env "$(token_line)" || return 1
    gitx commit -q --no-verify -m "bypassed on $1" || return 1
    gitx checkout -q main
}
base_commit() { stage_file README.md hello && gitx commit -q --no-verify -m base; }


test_real_catalog_a02_a_gitlab_token_is_blocked() {
    need_real_tools
    local tok
    tok="$(fake_gitlab_token)"
    new_repo a02 || return 1
    stage_file gl.env "GITLAB_TOKEN=$tok"
    commit_cap A02
    catalog A02 Block 'git commit -m A02 (gl.env with a fake glpat- token)'
    assert_blocked A02
    assert_contains "$ERR" "gitlab" "A02 a GitLab rule fired"
    no_leak "$tok"
}

test_real_catalog_a03_a_github_token_is_blocked() {
    need_real_tools
    new_repo a03 || return 1
    stage_file gh.env "GITHUB_TOKEN=$(fake_github_token)"
    commit_cap A03
    catalog A03 Block 'git commit -m A03 (gh.env with a fake ghp_ token)'
    assert_blocked A03
    no_leak "$(fake_github_token)"
}

test_real_catalog_a04_a_fresh_pem_and_openssh_private_key_are_blocked() {
    need_real_tools
    command -v openssl >/dev/null 2>&1 || skip_test "openssl not found"
    command -v ssh-keygen >/dev/null 2>&1 || skip_test "ssh-keygen not found"
    new_repo a04 || return 1
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out key.pem 2>/dev/null || return 1
    gitx add key.pem
    commit_cap A04-pem
    catalog A04a Block 'git commit -m A04-pem (freshly generated RSA PEM)'
    assert_blocked A04-pem
    gitx rm -q --cached key.pem && rm -f -- key.pem
    ssh-keygen -q -t ed25519 -N '' -C throwaway -f id_ed25519 >/dev/null 2>&1 || return 1
    gitx add id_ed25519
    commit_cap A04-openssh
    catalog A04b Block 'git commit -m A04-openssh (freshly generated ed25519 key)'
    assert_blocked A04-openssh
    assert_not_contains "$ERR" "PRIVATE KEY-----" "no key material printed"
}

test_real_catalog_a09_a_dotenv_and_an_appsettings_file_with_a_token_are_blocked() {
    need_real_tools
    new_repo a09 || return 1
    stage_file .env "GITHUB_TOKEN=$(fake_github_token)"
    commit_cap A09-env
    catalog A09a Block 'git commit -m A09 (.env)'
    assert_blocked A09-env
    gitx rm -q --cached .env
    stage_file appsettings.json '{' "  \"GitHub\": { \"Token\": \"$(fake_github_token)\" }" '}'
    commit_cap A09-json
    catalog A09b Block 'git commit -m A09 (appsettings.json)'
    assert_blocked A09-json
    no_leak "$(fake_github_token)"
}

test_real_catalog_a12_partial_staging_scans_the_index_not_the_work_tree() {
    need_real_tools
    local i
    new_repo a12 || return 1
    for i in $(seq 1 20); do printf 'k%s=%s\n' "$i" "$i"; done >app.cfg
    gitx add app.cfg && gitx commit -q --no-verify -m base
    { printf 'k1=1\n%s\n' "$(token_line)"; for i in $(seq 3 19); do printf 'k%s=%s\n' "$i" "$i"; done; printf 'k20=changed\n'; } >app.cfg
    printf 'n\ny\n' | gitx add -p app.cfg >/dev/null 2>&1
    commit_cap A12-clean-hunk
    catalog A12b Allow "printf 'n\\ny\\n' | git add -p app.cfg && git commit (only the clean hunk staged)"
    assert_rc 0 "A12 the unstaged token hunk is not scanned"
    printf 'y\n' | gitx add -p app.cfg >/dev/null 2>&1
    commit_cap A12-token-hunk
    catalog A12a Block "printf 'y\\n' | git add -p app.cfg && git commit (token hunk staged)"
    assert_blocked A12-token-hunk
    no_leak "$(fake_github_token)"
}

test_real_catalog_a13_a_pure_rename_adds_no_lines_and_passes_a_documented_gap() {
    need_real_tools
    new_repo a13 || return 1
    stage_file s/old.env "$(token_line)"
    gitx commit -q --no-verify -m planted
    gitx mv s/old.env s/new.env
    commit_cap A13-rename
    catalog A13a Record 'git mv s/old.env s/new.env && git commit (token already in history)'
    assert_rc 0 "A13 a pure rename passes"
    assert_contains "$ERR" "no added lines to scan" "A13 nothing was added"
    printf '%s\n' "$(token_line)" >>s/new.env
    gitx add s/new.env
    commit_cap A13-edit
    catalog A13b Block 'append a token to the renamed file && git commit'
    assert_blocked A13-edit
    no_leak "$(fake_github_token)"
}

test_real_catalog_a14_a_token_in_the_commit_message_is_blocked() {
    need_real_tools
    enable_message_hook
    new_repo a14 || return 1
    printf 'fix: rotate\n\n%s\n' "$(token_line)" >"$SANDBOX/msg14"
    stage_file x.txt hello
    run_cap gitx commit -q -F "$SANDBOX/msg14"
    catalog A14 Block 'git commit -F msg (token in the message only)'
    assert_blocked A14
    assert_contains "$ERR" "commit message:3" "A14 the finding is in the message, at its line"
    no_leak "$(fake_github_token)"
}

test_real_catalog_a15_an_amend_adding_a_token_is_blocked() {
    need_real_tools
    new_repo a15 || return 1
    base_commit || return 1
    stage_file c.env "$(token_line)"
    run_cap gitx commit -q --amend --no-edit
    catalog A15 Block 'git commit --amend --no-edit (token staged)'
    assert_blocked A15
    no_leak "$(fake_github_token)"
}

test_real_catalog_a16_crlf_and_paths_with_spaces_or_unicode_are_blocked() {
    need_real_tools
    new_repo a16 || return 1
    printf '%s\r\nx=1\r\n' "$(token_line)" >crlf.env
    gitx add crlf.env
    commit_cap A16-crlf
    catalog A16a Block 'git commit (CRLF file)'
    assert_blocked A16-crlf
    gitx rm -q --cached crlf.env
    stage_file "dir with space/ünï file.env" "$(token_line)"
    commit_cap A16-path
    catalog A16b Block 'git commit (path with spaces and unicode)'
    assert_blocked A16-path
    no_leak "$(fake_github_token)"
}

test_real_catalog_a17_a_binary_file_is_not_scanned_and_a_large_text_file_is() {
    need_real_tools
    new_repo a17 || return 1
    { printf '\0\0BIN'; token_line; printf '\n'; } >blob.bin
    gitx add blob.bin
    commit_cap A17-binary
    catalog A17a Record 'git commit (file with a NUL byte holding a token)'
    assert_rc 0 "A17 binary content is not extracted"
    { head -c 3000000 /dev/zero | tr '\0' 'a' | fold -w 100; printf '\n%s\n' "$(token_line)"; } >big.txt
    gitx add big.txt
    commit_cap A17-large
    catalog A17b Record 'git commit (3 MB text file, token on the last line)'
    assert_blocked A17-large
    no_leak "$(fake_github_token)"
}

test_real_catalog_a18_a_notebook_cell_is_blocked() {
    need_real_tools
    new_repo a18 || return 1
    # shellcheck disable=SC2016
    "$TEST_JQ" -n --arg t "$(token_line)" '{cells:[{cell_type:"code",source:[$t]}],nbformat:4}' >nb.ipynb || return 1
    gitx add nb.ipynb
    commit_cap A18
    catalog A18 Block 'git commit (token inside a notebook cell)'
    assert_blocked A18
    no_leak "$(fake_github_token)"
}


test_real_catalog_b01_aws_documentation_keys_and_placeholders() {
    need_real_tools
    new_repo b01 || return 1
    stage_file docs.md "aws_access_key_id = $(aws_doc_key_id)" "aws_secret_access_key = $(aws_doc_secret)" \
        'password = changeme' 'token = <TOKEN>'
    commit_cap B01
    catalog B01 Allow 'git commit (AWS documentation example keys and placeholders)'
    [ "$(catalog_actual)" != Error ] || fail "B01 the hook errored: ${ERR:0:300}"
    no_leak "$(aws_doc_secret)"
}

test_real_catalog_b02_lockfile_hashes_uuids_and_data_uris() {
    need_real_tools
    new_repo b02 || return 1
    printf '{\n  "packages": {\n    "node_modules/x": { "integrity": "sha512-%s==" }\n  }\n}\n' \
        "$(LC_ALL=C tr -dc 'A-Za-z0-9+/' </dev/urandom | head -c 86 || true)" >package-lock.json
    printf 'id: 3f2b6c1e-4a5d-4e8f-9b0a-1c2d3e4f5a6b\nsha256: %s\n' "$(LC_ALL=C tr -dc 'a-f0-9' </dev/urandom | head -c 64 || true)" >ids.yml
    printf '<img src="data:image/png;base64,%s">\n' "$(head -c 600 /dev/urandom | base64 | tr -d '\n')" >page.html
    gitx add .
    commit_cap B02
    catalog B02 Allow 'git commit (lockfile integrity hashes, UUID, sha256, base64 image)'
    [ "$(catalog_actual)" != Error ] || fail "B02 the hook errored: ${ERR:0:300}"
}

test_real_catalog_b04_a_clean_commit_prints_only_the_pass_line() {
    need_real_tools
    new_repo b04 || return 1
    stage_file clean.txt "nothing secret here"
    commit_cap B04
    catalog B04 Allow 'git commit (clean file)'
    assert_rc 0 "B04 commits"
    assert_pass_line_only "$ERR" "B04 pass line"
}


test_real_catalog_c04_each_kill_switch_skips_the_hook_without_a_trace() {
    need_real_tools
    new_repo c04 || return 1
    stage_file k.env "$(token_line)"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GIT_CONFIG_PARAMETERS="'hook.git-secret-guard.enabled'='false'" "$GIT" commit -q -m C04a
    catalog C04a Detect "GIT_CONFIG_PARAMETERS=\"'hook.git-secret-guard.enabled'='false'\" git commit"
    assert_hook_never_ran C04a
    gitx update-ref -d HEAD
    run_cap gitx -c hook.git-secret-guard.enabled=false commit -q -m C04b
    catalog C04b Detect 'git -c hook.git-secret-guard.enabled=false commit'
    assert_hook_never_ran C04b
    gitx update-ref -d HEAD
    gitx config hook.git-secret-guard.enabled false
    commit_cap C04c
    catalog C04c Detect 'git config hook.git-secret-guard.enabled false && git commit'
    assert_hook_never_ran C04c
    no_leak "$(fake_github_token)"
}

test_real_catalog_c05_encoded_and_split_tokens() {
    need_real_tools
    local tok
    tok="$(fake_github_token)"
    new_repo c05 || return 1
    stage_file b64.txt "blob = $(printf '%s' "$tok" | base64)"
    commit_cap C05-base64
    catalog C05a Gap 'git commit (base64 of a token)'
    [ "$(catalog_actual)" != Error ] || fail "C05 base64 errored: ${ERR:0:300}"
    gitx rm -q --cached b64.txt
    printf 't = "%s" + \\\n    "%s"\n' "${tok:0:20}" "${tok:20}" >c.py
    gitx add c.py
    commit_cap C05-concat
    catalog C05b Gap 'git commit (token split across two string literals)'
    [ "$(catalog_actual)" != Error ] || fail "C05 concat errored: ${ERR:0:300}"
    no_leak "$tok"
}


test_real_catalog_d01_d02_no_verify_skips_the_scan() {
    need_real_tools
    new_repo d01 || return 1
    stage_file k.env "$(token_line)"
    commit_cap D01 --no-verify
    catalog D01 Detect 'git commit --no-verify'
    assert_hook_never_ran D01
    gitx update-ref -d HEAD
    commit_cap D02 -n
    catalog D02 Detect 'git commit -n'
    assert_hook_never_ran D02
}

test_real_catalog_d03_to_d08_core_hooks_path_cannot_switch_the_config_hook_off() {
    need_real_tools
    mkdir -p -- "$SANDBOX/emptyhooks"
    printf '[core]\n\thooksPath = %s\n' "$SANDBOX/emptyhooks" >"$SANDBOX/inc-hp.cfg"
    new_repo d03 || return 1
    stage_file k.env "$(token_line)"
    run_cap gitx -c core.hooksPath= commit -q -m D03a
    catalog D03a Detect 'git -c core.hooksPath= commit'
    assert_blocked D03a
    run_cap gitx -c core.hooksPath="$SANDBOX/emptyhooks" commit -q -m D03b
    catalog D03b Detect 'git -c core.hooksPath=<empty dir> commit'
    assert_blocked D03b
    gitx config --global core.hooksPath "$SANDBOX/emptyhooks"
    commit_cap D04
    catalog D04 Detect 'git config --global core.hooksPath <empty dir> && git commit'
    assert_blocked D04
    gitx config --global --unset core.hooksPath
    gitx config --local core.hooksPath "$SANDBOX/emptyhooks"
    commit_cap D05
    catalog D05 Detect 'git config --local core.hooksPath <empty dir> && git commit'
    assert_blocked D05
    gitx config --local --unset core.hooksPath
    gitx config --local include.path "$SANDBOX/inc-hp.cfg"
    commit_cap D08a
    catalog D08a Detect 'git config --local include.path <file setting core.hooksPath> && git commit'
    assert_blocked D08a
    no_leak "$(fake_github_token)"
}

test_real_catalog_d07_an_alternate_global_config_or_injected_keys_skip_the_hook() {
    need_real_tools
    : >"$SANDBOX/empty.gitconfig"
    new_repo d07 || return 1
    stage_file k.env "$(token_line)"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GIT_CONFIG_GLOBAL="$SANDBOX/empty.gitconfig" \
        "$GIT" -c user.name=t -c user.email=t@example.invalid commit -q -m D07a
    catalog D07a Detect 'GIT_CONFIG_GLOBAL=<empty file> git commit'
    assert_hook_never_ran D07a
    gitx update-ref -d HEAD
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.git-secret-guard.enabled \
        GIT_CONFIG_VALUE_0=false "$GIT" commit -q -m D07b
    catalog D07b Detect 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.git-secret-guard.enabled GIT_CONFIG_VALUE_0=false git commit'
    assert_hook_never_ran D07b
    gitx update-ref -d HEAD
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.git-secret-guard.command \
        GIT_CONFIG_VALUE_0=true "$GIT" commit -q -m D07c
    catalog D07c Detect 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=hook.git-secret-guard.command GIT_CONFIG_VALUE_0=true git commit'
    assert_hook_never_ran D07c
    no_leak "$(fake_github_token)"
}

test_real_catalog_d08_an_include_disabling_the_hook_skips_it() {
    need_real_tools
    printf '[hook "git-secret-guard"]\n\tenabled = false\n' >"$SANDBOX/inc-off.cfg"
    new_repo d08 || return 1
    stage_file k.env "$(token_line)"
    gitx config --local include.path "$SANDBOX/inc-off.cfg"
    commit_cap D08b
    catalog D08b Detect 'git config --local include.path <file with enabled=false> && git commit'
    assert_hook_never_ran D08b
}

test_real_catalog_d09_an_alias_with_no_verify_skips_the_scan() {
    need_real_tools
    new_repo d09 || return 1
    stage_file k.env "$(token_line)"
    gitx config --global alias.ci "commit --no-verify"
    run_cap gitx ci -q -m D09
    gitx config --global --unset alias.ci
    catalog D09 Detect 'git config --global alias.ci "commit --no-verify" && git ci'
    assert_hook_never_ran D09
}

test_real_catalog_d11_a_hook_without_its_exec_bit_still_stops_the_commit() {
    need_real_tools
    new_repo d11 || return 1
    stage_file k.env "$(token_line)"
    chmod -x -- "$SHARE/hooks/secret-scan"
    commit_cap D11
    restore_hook_files || return 1
    catalog D11 Detect 'chmod -x <share>/hooks/secret-scan && git commit'
    [ "$RC" -ne 0 ] || fail "D11 a hook git cannot start let the commit through"
}

test_real_catalog_d12_scanners_shadowed_on_path_are_not_used() {
    need_real_tools
    local t
    mkdir -p -- "$SANDBOX/shadow"
    for t in trufflehog betterleaks; do printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/shadow/$t" && chmod 755 -- "$SANDBOX/shadow/$t"; done
    set_env PATH="$SANDBOX/shadow:$REAL_HOME/.local/bin:$TEST_BASE_PATH"
    new_repo d12 || return 1
    stage_file k.env "$(token_line)"
    commit_cap D12
    catalog D12 Block 'PATH=<dir with no-op trufflehog and betterleaks>:<PATH> git commit'
    assert_blocked D12
}

test_real_catalog_d13_a_missing_or_crashing_scanner_or_a_missing_rule_file_fails_closed() {
    need_real_tools "BETTERLEAKS_BIN=/nonexistent/betterleaks"
    new_repo d13 || return 1
    stage_file k.env "$(token_line)"
    commit_cap D13a
    catalog D13a FailClosed 'settings BETTERLEAKS_BIN=/nonexistent/betterleaks && git commit'
    assert_blocked_unscanned D13a
    printf '#!/bin/sh\necho boom >&2\nexit 2\n' >"$SANDBOX/crash" && chmod 755 -- "$SANDBOX/crash"
    real_tools_with "TRUFFLEHOG_BIN=$SANDBOX/crash"
    commit_cap D13b
    catalog D13b Block 'settings TRUFFLEHOG_BIN=<script exiting 2> && git commit'
    assert_rc 1 "D13b blocked"
    assert_contains "$ERR" "trufflehog: scan failed (exit 2)" "D13b the crash is reported and blocks"
    real_tools_with
    rm -f -- "$SHARE/lib/betterleaks-rule.toml"
    commit_cap D13c
    restore_hook_files || return 1
    catalog D13c FailClosed 'rm <share>/lib/betterleaks-rule.toml && git commit'
    assert_rc 1 "D13c blocked"
    assert_contains "$ERR" "betterleaks: the shipped rule file" "D13c the missing rule file is reported and blocks"
    no_leak "$(fake_github_token)"
}

test_real_catalog_d14_a_plumbing_commit_runs_no_hook() {
    need_real_tools
    local blob tree commit
    new_repo d14 || return 1
    base_commit || return 1
    printf '%s\n' "$(token_line)" >"$SANDBOX/tok14"
    blob="$(gitx hash-object -w "$SANDBOX/tok14")" || return 1
    tree="$(printf '100644 blob %s\tk.env\n' "$blob" | gitx mktree)" || return 1
    commit="$(gitx commit-tree "$tree" -p HEAD -m D14)" || return 1
    run_cap gitx update-ref refs/heads/main "$commit"
    catalog D14 Detect 'git hash-object -w && git mktree && git commit-tree && git update-ref'
    assert_hook_never_ran D14
    assert_eq "$(gitx rev-parse HEAD)" "$commit" "D14 the token commit is on main"
}

test_real_catalog_d15_a_merge_is_not_scanned_and_a_conflict_resolution_commit_is() {
    need_real_tools
    new_repo d15 || return 1
    base_commit || return 1
    commit_token_on_branch feat || return 1
    run_cap gitx merge -q --no-ff -m D15a feat
    catalog D15a Server 'git merge --no-ff feat (branch commit made with --no-verify)'
    assert_hook_never_ran D15a
    new_repo d15b || return 1
    base_commit || return 1
    gitx checkout -q -b side && stage_file README.md side && gitx commit -q --no-verify -m side
    gitx checkout -q main && stage_file README.md main && gitx commit -q --no-verify -m main
    gitx merge -q side >/dev/null 2>&1
    printf '%s\n' "$(token_line)" >README.md
    gitx add README.md
    run_cap gitx commit -q --no-edit
    catalog D15b Block 'git merge side (conflict) && resolve with a token && git commit --no-edit'
    assert_blocked D15b
    no_leak "$(fake_github_token)"
}

test_real_catalog_d16_cherry_pick_rebase_and_am_replay_a_bypassed_token_unscanned() {
    need_real_tools
    new_repo d16 || return 1
    base_commit || return 1
    commit_token_on_branch feat || return 1
    run_cap gitx cherry-pick feat
    catalog D16a Gap 'git cherry-pick feat'
    assert_hook_never_ran D16a
    new_repo d16b || return 1
    base_commit || return 1
    commit_token_on_branch feat || return 1
    stage_file o.txt other && gitx commit -q --no-verify -m other
    gitx checkout -q feat
    run_cap gitx rebase -q main
    catalog D16b Gap 'git checkout feat && git rebase main'
    assert_hook_never_ran D16b
    new_repo d16c || return 1
    base_commit || return 1
    commit_token_on_branch feat || return 1
    gitx format-patch -q -1 feat -o "$SANDBOX/p16" >/dev/null || return 1
    run_cap gitx am -q "$SANDBOX"/p16/*.patch
    catalog D16c Gap 'git format-patch -1 feat && git am'
    assert_hook_never_ran D16c
}

test_real_catalog_d18_d19_d20_worktrees_submodules_and_new_repositories_are_covered() {
    need_real_tools
    local sub
    new_repo d18 || return 1
    base_commit || return 1
    run_cap gitx worktree add -q -b wt "$SANDBOX/wt18"
    [ "$RC" -eq 0 ] || { fail "D18 setup git worktree add failed: ${ERR:0:300}"; return 1; }
    cd -- "$SANDBOX/wt18" || return 1
    stage_file k.env "$(token_line)"
    commit_cap D18
    catalog D18 Block 'git worktree add && git commit in the worktree'
    assert_blocked D18
    set_env PATH="$(dirname -- "$GIT"):$REAL_HOME/.local/bin:$TEST_BASE_PATH"
    new_repo d19sub || return 1
    base_commit || return 1
    sub="$REPO"
    new_repo d19 || return 1
    base_commit || return 1
    run_cap gitx -c protocol.file.allow=always submodule add -q "$sub" sub
    [ "$RC" -eq 0 ] || { fail "D19 setup git submodule add failed: ${ERR:0:300}"; return 1; }
    cd -- "$REPO/sub" || return 1
    stage_file k.env "$(token_line)"
    commit_cap D19
    catalog D19 Block 'git commit inside a submodule'
    assert_blocked D19
    mkdir -p -- "$SANDBOX/emptytpl"
    run_cap gitx clone -q --template="$SANDBOX/emptytpl" "$sub" "$SANDBOX/repos/d20"
    [ "$RC" -eq 0 ] || { fail "D20 setup git clone failed: ${ERR:0:300}"; return 1; }
    cd -- "$SANDBOX/repos/d20" || return 1
    stage_file k.env "$(token_line)"
    commit_cap D20
    catalog D20 Block 'git clone --template=<empty dir> && git commit'
    assert_blocked D20
    no_leak "$(fake_github_token)"
}


test_real_catalog_n01_a_replaced_hook_script_lets_a_token_through() {
    need_real_tools
    new_repo n01 || return 1
    stage_file k.env "$(token_line)"
    printf '#!/bin/sh\nexit 0\n' >"$SHARE/hooks/secret-scan"
    commit_cap N01
    restore_hook_files || return 1
    catalog N01 Detect 'overwrite <share>/hooks/secret-scan with "exit 0" (user-writable) && git commit'
    assert_hook_never_ran N01
}

test_real_catalog_n02_a_find_shadowed_on_path() {
    need_real_tools
    mkdir -p -- "$SANDBOX/shadow-find"
    printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/shadow-find/find" && chmod 755 -- "$SANDBOX/shadow-find/find"
    set_env PATH="$SANDBOX/shadow-find:$REAL_HOME/.local/bin:$TEST_BASE_PATH"
    new_repo n02 || return 1
    stage_file k.env "$(token_line)"
    commit_cap N02
    catalog N02 Block 'PATH=<dir with a no-op find>:<PATH> git commit'
    no_leak "$(fake_github_token)"
}

test_real_catalog_n05_n08_removing_or_overriding_the_hook_command_skips_the_scan() {
    need_real_tools
    new_repo n05 || return 1
    stage_file k.env "$(token_line)"
    gitx config --global --remove-section hook.git-secret-guard
    commit_cap N05
    configure_hook
    catalog N05 Detect 'git config --global --remove-section hook.git-secret-guard && git commit'
    assert_hook_never_ran N05
    gitx update-ref -d HEAD
    gitx config --local hook.git-secret-guard.command true
    commit_cap N08
    catalog N08 Detect 'git config --local hook.git-secret-guard.command true && git commit'
    assert_hook_never_ran N08
}

run_file_tests
