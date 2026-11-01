#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

# ^ external only the real gitleaks decides what a config means; the settings are pointed at it after the fixture install
dr_real_gitleaks() {
    [ -x "$REAL_GITLEAKS" ] || skip_test "gitleaks not found at $REAL_GITLEAKS"
    dr_begin && dr_repo "$1" || return 1
    sed -i "s#^GITLEAKS_BIN=.*#GITLEAKS_BIN=$REAL_GITLEAKS#" "$LC_DATA/settings" || return 1
    cd -- "$DR_ROOTS/$1" || return 1
}

commit_gitleaks_config() {
    stage_file .gitleaks.toml "$@" || return 1
    gitx commit -q --no-verify -m "add the gitleaks config"
}

test_a_gitleaks_config_that_does_not_load_on_its_own_is_a_problem() {
    dr_real_gitleaks extends || return 1
    commit_gitleaks_config '[extend]' 'path = "base.toml"' || return 1
    doctor
    assert_rc 1 "an [extend] path cannot resolve in the hook"
    assert_contains "$OUT" "  $DR_REAL/extends
    PROBLEM  .gitleaks.toml at HEAD does not load on its own (gitleaks said: " "listed with gitleaks' own words"
    assert_contains "$OUT" "commit blocked, nothing was scanned." "and the consequence"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "not covered"
}

test_a_config_without_use_default_warns_that_built_in_rules_are_off() {
    dr_real_gitleaks bare || return 1
    commit_gitleaks_config '[[rules]]' 'id = "mine"' "regex = '''zzz-never-matches-zzz'''" || return 1
    doctor
    assert_rc 0 "a warning does not change the exit status"
    assert_contains "$OUT" "    WARNING  with .gitleaks.toml at HEAD, gitleaks does not detect its own built-in rules (e.g. AWS access keys): either [extend] useDefault = true is missing, or an allowlist or disabledRules turns them off; trufflehog still runs" "the hook's own sentence"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "the hook still runs"
    assert_not_contains "$OUT" "$(probe_secret)" "the probe value is never printed"
}

test_a_config_that_keeps_the_default_rules_is_silent() {
    dr_real_gitleaks quiet || return 1
    commit_gitleaks_config '[extend]' 'useDefault = true' || return 1
    doctor
    assert_rc 0 "a sound config"
    assert_not_contains "$OUT" "repos with findings" "nothing to list"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "covered"
}

test_a_gitleaks_that_cannot_run_makes_the_config_check_an_explicit_warning() {
    dr_real_gitleaks blind || return 1
    commit_gitleaks_config '[extend]' 'useDefault = true' || return 1
    sed -i 's#^GITLEAKS_BIN=.*#GITLEAKS_BIN=/nonexistent/gitleaks#' "$LC_DATA/settings" || return 1
    doctor
    assert_rc 1 "the machine section already has the problem"
    assert_contains "$OUT" "    WARNING  .gitleaks.toml at HEAD was not checked: gitleaks or timeout is unusable (see the machine section)" "never skipped silently"
}

test_a_gitleaks_config_that_is_a_symlink_at_head_is_a_problem() {
    dr_real_gitleaks linked || return 1
    ln -s /etc/hostname .gitleaks.toml && gitx add .gitleaks.toml && gitx commit -q --no-verify -m link || return 1
    doctor
    assert_rc 1 "a symlink at HEAD"
    assert_contains "$OUT" "PROBLEM  .gitleaks.toml at HEAD must be a regular file (a symlink or directory is refused); every commit in this repository is blocked" "refused like the hook does"
}

test_a_config_that_takes_too_long_to_load_times_out_under_the_settings_limit() {
    dr_begin && dr_repo slow || return 1
    cd -- "$DR_ROOTS/slow" || return 1
    commit_gitleaks_config '[extend]' 'useDefault = true' || return 1
    sed -i "s#^GITLEAKS_BIN=.*#GITLEAKS_BIN=$STUBS_DIR/gitleaks#; s#^SCAN_TIMEOUT_SECONDS=.*#SCAN_TIMEOUT_SECONDS=1#" "$LC_DATA/settings" || return 1
    set_env STUB_GL_PREFLIGHT_SLEEP=5
    doctor
    assert_rc 1 "a pre-flight that exceeds the limit"
    assert_contains "$OUT" "PROBLEM  gitleaks did not finish loading .gitleaks.toml at HEAD within 1s; commit blocked, nothing was scanned." "the limit from the settings"
}

test_the_preflight_runs_under_doctors_own_smaller_limit() {
    local start
    dr_begin && dr_repo slow || return 1
    cd -- "$DR_ROOTS/slow" || return 1
    commit_gitleaks_config '[extend]' 'useDefault = true' || return 1
    sed -i "s#^GITLEAKS_BIN=.*#GITLEAKS_BIN=$STUBS_DIR/gitleaks#" "$LC_DATA/settings" || return 1
    printf 'DOCTOR_TIMEOUT_SECONDS=1\n' >>"$LC_DATA/settings" || return 1
    set_env STUB_GL_PREFLIGHT_SLEEP=8
    start="$(date +%s)"
    doctor
    assert_rc 1 "a pre-flight that exceeds doctor's limit but not the hook's 300 s"
    [ "$(($(date +%s) - start))" -lt 14 ] || fail "doctor waited $(($(date +%s) - start)) s (the stand-in also sleeps once for the machine version probe)"
    assert_contains "$OUT" "PROBLEM  gitleaks timed out after 1s loading .gitleaks.toml at HEAD (doctor's limit; the hook allows 300s), so doctor could not judge it" "says whose limit it was"
}

run_file_tests
