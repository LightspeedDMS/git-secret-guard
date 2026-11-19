#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/autoupdate/autoupdate.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/autoupdate.sh"

ESC=$'\e'
OK_ICON="${ESC}[32m✓${ESC}[0m"
INFO_ICON="${ESC}[2m•${ESC}[0m"
PROBLEM_ICON="${ESC}[31m✗${ESC}[0m"

test_a_skipped_update_gets_the_info_icon() {
    au_setup_with_release || return 1
    gitx -C "$AU_CO" remote rename origin elsewhere || return 1
    ui_force_terminal
    upd
    assert_rc 0 "a skip is not an error"
    assert_contains "$OUT" "$INFO_ICON git-secret-guard: update: skipped (no-origin)" "skip = info"
}

test_a_current_and_an_updated_update_get_the_ok_icon() {
    au_setup || return 1
    ui_force_terminal
    upd
    assert_rc 0 "current"
    assert_contains "$OUT" "$OK_ICON git-secret-guard: update: current" "current = ok"
    au_release 1.1.0 && au_publish || return 1
    upd
    assert_rc 0 "updated"
    assert_contains "$OUT" "$OK_ICON git-secret-guard: update: updated 1.0.0 -> 1.1.0" "updated = ok"
}

test_a_failed_update_gets_the_problem_icon_on_stderr() {
    au_setup || return 1
    au_broken_installer 'echo "git-secret-guard: refused" >&2; exit 1' && au_release 1.1.0 && au_publish || return 1
    ui_force_terminal
    upd
    assert_rc 1 "failed"
    assert_contains "$ERR" "$PROBLEM_ICON git-secret-guard: update: failed" "failed = problem"
}

test_the_child_install_of_update_runs_without_clicolor_force() {
    au_setup || return 1
    au_broken_installer 'printf "%s\n" "${CLICOLOR_FORCE-unset}" >"'"$SANDBOX"'/au-child.color"; echo "git-secret-guard: refused" >&2; exit 1' && au_release 1.1.0 && au_publish || return 1
    ui_force_terminal
    upd
    assert_rc 1 "the stand-in installer refuses"
    assert_eq "$(<"$SANDBOX/au-child.color")" unset "the child does not see CLICOLOR_FORCE"
    assert_not_contains "$(rec detail)" "$ESC" "no escape code reaches the record's detail"
}

run_file_tests
