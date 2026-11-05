#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck disable=SC2016
in_common() {
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'set -u; source "$1/lib/common.sh"; eval "$2"' _ "$SHARE" "$1"
}

# shellcheck disable=SC2016
test_first_message_of_a_missing_file_is_empty_and_prints_no_shell_error() {
    in_common "first_message '$SANDBOX/no-such-error-file'; printf '[%s]' \"\$REPLY\""
    assert_rc 0 "first_message"
    assert_eq "$OUT" "[]" "an empty message"
    assert_empty "$ERR" "and no bash redirection error"
}

# shellcheck disable=SC2016
test_trunc_text_marks_a_cut_and_leaves_a_fitting_value_alone() {
    in_common 'trunc_text abcdef 3; printf "[%s]" "$REPLY"; trunc_text abc 3; printf "[%s]" "$REPLY"; trunc_text ab 3; printf "[%s]" "$REPLY"; trunc_text "" 3; printf "[%s]" "$REPLY"'
    assert_rc 0 "trunc_text"
    assert_eq "$OUT" "[abc…][abc][ab][]" "longer is cut and marked, equal and shorter are whole"
}

test_load_settings_reads_the_three_tools_and_defaults_the_timeout() {
    write_settings /a/t /a/g /a/j
    in_common "load_settings '$SHARE/settings' && printf '%s %s %s %s' \"\$TRUFFLEHOG_BIN\" \"\$BETTERLEAKS_BIN\" \"\$JQ_BIN\" \"\$SCAN_TIMEOUT_SECONDS\""
    assert_rc 0 load_settings
    assert_eq "$OUT" "/a/t /a/g /a/j 300" "values and default timeout"
}

test_load_settings_takes_an_explicit_timeout() {
    write_settings /a/t /a/g /a/j "SCAN_TIMEOUT_SECONDS=45"
    in_common "load_settings '$SHARE/settings' && printf '%s' \"\$SCAN_TIMEOUT_SECONDS\""
    assert_eq "$OUT" 45 "timeout from the settings file"
}

test_load_settings_ignores_inherited_tool_variables() {
    printf 'JQ_BIN=/a/j\n' >"$SHARE/settings"
    set_env TRUFFLEHOG_BIN=/env/t BETTERLEAKS_BIN=/env/g SCAN_TIMEOUT_SECONDS=1
    in_common "load_settings '$SHARE/settings' && printf '[%s][%s][%s]' \"\${TRUFFLEHOG_BIN:-}\" \"\${BETTERLEAKS_BIN:-}\" \"\$SCAN_TIMEOUT_SECONDS\""
    assert_eq "$OUT" "[][][300]" "environment values are discarded"
}

test_load_settings_discards_the_old_gitleaks_names() {
    printf 'JQ_BIN=/a/j\n' >"$SHARE/settings"
    set_env GITLEAKS_BIN=/env/g GITLEAKS_VERSION=8.30.1
    in_common "load_settings '$SHARE/settings' && printf '[%s][%s]' \"\${GITLEAKS_BIN:-}\" \"\${GITLEAKS_VERSION:-}\""
    assert_eq "$OUT" "[][]" "the names of the scanner this build replaced are cleared too"
}

test_load_settings_discards_an_inherited_doctor_time_limit() {
    printf 'JQ_BIN=/a/j\n' >"$SHARE/settings"
    set_env DOCTOR_TIMEOUT_SECONDS=1
    in_common "load_settings '$SHARE/settings' && printf '[%s]' \"\${DOCTOR_TIMEOUT_SECONDS:-}\""
    assert_eq "$OUT" "[]" "only the settings file can set doctor's limit"
}

test_load_settings_reads_setsid_and_timeout_and_discards_inherited_values() {
    write_settings /a/t /a/g /a/j
    set_env SETSID_BIN=/env/setsid TIMEOUT_BIN=/env/timeout
    in_common "load_settings '$SHARE/settings' && printf '[%s][%s]' \"\${SETSID_BIN:-}\" \"\$TIMEOUT_BIN\""
    assert_eq "$OUT" "[$TEST_SETSID][$TEST_TIMEOUT]" "settings win"
    printf 'JQ_BIN=/a/j\n' >"$SHARE/settings"
    in_common "load_settings '$SHARE/settings' && printf '[%s][%s]' \"\${SETSID_BIN:-}\" \"\${TIMEOUT_BIN:-}\""
    assert_eq "$OUT" "[][]" "an inherited value never fills a gap"
}

test_strip_ansi_removes_colour_sequences_and_nothing_else() {
    in_common "strip_ansi \"\$(printf '\\033[90m5:45AM\\033[0m \\033[31mFTL\\033[0m \\033[1mFailed to load\\033[0m \\033[36merror=\\033[0m[x]')\""
    assert_eq "$OUT" "5:45AM FTL Failed to load error=[x]" "colour codes gone, brackets and text kept"
    in_common "strip_ansi 'plain [31m text'"
    assert_eq "$OUT" "plain [31m text" "no escape character, no change"
}

test_load_settings_rejects_bad_timeouts() {
    local bad
    for bad in 0 abc -5 "" 1.5; do
        write_settings /a/t /a/g /a/j "SCAN_TIMEOUT_SECONDS=\"$bad\""
        in_common "load_settings '$SHARE/settings'"
        assert_rc 1 "timeout [$bad] refused"
        assert_contains "$ERR" "SCAN_TIMEOUT_SECONDS" "names the setting"
    done
}

test_load_settings_fails_on_a_missing_file() {
    in_common "load_settings '$SANDBOX/nope'"
    assert_rc 1 "missing settings"
    assert_contains "$ERR" "missing or unreadable" "says why"
}

test_load_settings_fails_when_the_file_does_not_source_cleanly() {
    printf 'false\n' >"$SHARE/settings"
    in_common "load_settings '$SHARE/settings'"
    assert_rc 1 "a failing settings file is not ignored"
}

test_tool_unusable_classifies_every_case() {
    local plain="$SANDBOX/plain-file" good="$SANDBOX/good-tool"
    : >"$plain" && chmod 644 "$plain"
    printf '#!/bin/sh\n' >"$good" && chmod 755 "$good"
    in_common "tool_unusable t ''"
    assert_rc 0 "empty is unusable"
    assert_contains "$OUT" "not configured" empty
    in_common "tool_unusable t relative/path"
    assert_contains "$OUT" "absolute" relative
    in_common "tool_unusable t '$SANDBOX/missing'"
    assert_contains "$OUT" "missing or not executable" missing
    in_common "tool_unusable t '$SANDBOX'"
    assert_contains "$OUT" "missing or not executable" "a directory is not a tool"
    in_common "tool_unusable t '$plain'"
    assert_contains "$OUT" "missing or not executable" "non-executable"
    in_common "tool_unusable t '$good'"
    assert_rc 1 "an absolute executable file is fine"
    assert_empty "$OUT" "and prints nothing"
}

test_run_scanner_refuses_bad_arguments_and_missing_settings() {
    run_cap env -i "${GSG_ENV[@]}" bash "$SHARE/lib/run-scanner.sh" bogus "$SANDBOX" "$SANDBOX"
    assert_rc 2 "unknown scanner name"
    assert_contains "$ERR" "unknown scanner" "says why"
    run_cap env -i "${GSG_ENV[@]}" bash "$SHARE/lib/run-scanner.sh" trufflehog "$SANDBOX"
    assert_rc 2 "missing argument"
    assert_contains "$ERR" "expected 3 arguments" "says why"
    rm -f -- "$SHARE/settings"
    run_cap env -i "${GSG_ENV[@]}" bash "$SHARE/lib/run-scanner.sh" betterleaks "$SANDBOX" "$SANDBOX"
    assert_rc 1 "unreadable settings stop the runner"
}

test_report_results_refuses_a_missing_work_dir() {
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/common.sh"; source "$1/lib/report.sh"; report_results ""' _ "$SHARE"
    assert_rc 1 "no work dir"
    assert_contains "$ERR" "failing closed" "says why"
}

test_hook_blocks_on_an_invalid_timeout_setting() {
    new_repo badtimeout || return 1
    use_stubs "SCAN_TIMEOUT_SECONDS=soon"
    stage_file a.txt one
    commit_cap "x"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "SCAN_TIMEOUT_SECONDS" "names the setting"
    assert_contains "$ERR" "nothing was scanned" "says nothing was scanned"
}

run_file_tests
