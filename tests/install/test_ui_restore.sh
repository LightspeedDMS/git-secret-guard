#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup.sh"
# shellcheck source=tests/support/gitup_macos.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup_macos.sh"
# shellcheck source=tests/support/smartgit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/smartgit.sh"
# shellcheck source=tests/support/gitup_windows.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup_windows.sh"

ESC=$'\e'
OK_ICON="${ESC}[32m✓${ESC}[0m"
WARNING_ICON="${ESC}[33m▲${ESC}[0m"

test_restore_smartgit_marks_its_restored_line_and_adds_no_line() {
    sg_setup || return 1
    sg_real_tools || return 1
    sg_lfs_present || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "install --configure-smartgit"
    ui_force_terminal
    gsg restore-smartgit
    assert_rc 0 "restore-smartgit"
    assert_contains "$OUT" "$OK_ICON git-secret-guard: restored the Git Executable of $SG_PREFS from the backup" "the existing line carries the icon"
    assert_not_contains "$OUT$ERR" "restore-smartgit done" "no trailer"
}

test_the_git_upgrade_hand_off_line_carries_the_warning_icon_and_nothing_is_added() {
    wu_begin machine 2.52.0.1 || return 1
    wu_fixture good || return 1
    wu_elevated yes
    ui_force_terminal
    wu 'GSG_GIT="$1"; GITUP_PENDING=1; gitup_offers 1 0; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=3" "install stops with the hand-off status"
    assert_contains "$OUT" "$WARNING_ICON git-secret-guard: the git upgrade must be finished outside this process" "the existing line carries the icon"
    assert_not_contains "$OUT$ERR" "stopped at a step you finish yourself" "no trailer"
}

run_file_tests
