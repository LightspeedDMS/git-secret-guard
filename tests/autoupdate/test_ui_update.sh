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

# ^ why one test and one setup, not one test per icon; the steps run in terminal mode on one checkout and assert what the CLI prints
# ^ invariant skipped (origin renamed) -> updated -> current -> failed (the installer of the published 1.2.0 refuses); the origin is back before the update
test_the_update_output_gets_the_icon_of_its_outcome_and_the_child_install_gets_no_color_force() {
    au_setup_with_release || return 1
    ui_force_terminal
    gitx -C "$AU_CO" remote rename origin elsewhere || return 1
    upd
    assert_rc 0 "a skip is not an error"
    assert_contains "$OUT" "$INFO_ICON git-secret-guard: update: skipped (no-origin)" "skip = info"
    gitx -C "$AU_CO" remote rename elsewhere origin || return 1

    upd
    assert_rc 0 "updated"
    assert_contains "$OUT" "$OK_ICON git-secret-guard: update: updated 1.0.0 -> 1.1.0" "updated = ok"
    upd
    assert_rc 0 "current"
    assert_contains "$OUT" "$OK_ICON git-secret-guard: update: current" "current = ok"

    au_broken_installer 'printf "%s\n" "${CLICOLOR_FORCE-unset}" >"'"$SANDBOX"'/au-child.color"; echo "git-secret-guard: refused" >&2; exit 1' && au_release 1.2.0 && au_publish || return 1
    upd
    assert_rc 1 "failed: the stand-in installer refuses"
    assert_contains "$ERR" "$PROBLEM_ICON git-secret-guard: update: failed" "failed = problem"
    assert_eq "$(<"$SANDBOX/au-child.color")" unset "the child does not see CLICOLOR_FORCE"
    assert_not_contains "$(rec detail)" "$ESC" "no escape code reaches the record's detail"
}

run_file_tests
