#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

ESC=$'\e'
OK_ICON="${ESC}[32m✓${ESC}[0m"

# ^ invariant the last line of a text
last_line() { printf '%s' "${1##*$'\n'}"; }

test_install_puts_the_ok_icon_on_its_outcome_line_in_terminal_mode_only() {
    local want
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    want="$(<"$GSG_PROJECT/VERSION")" || return 1
    ui_force_terminal
    gsg install
    assert_rc 0 "install"
    assert_eq "$(head -n 1 <<<"$OUT")" "$OK_ICON git-secret-guard: installed git-secret-guard $want" "icon, one space, the unchanged line"
    assert_eq "$(grep -c "$ESC" <<<"$OUT")" 1 "no other line of install carries an escape sequence"
}

test_install_in_plain_mode_prints_no_escape_sequence_and_no_extra_line() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    assert_not_contains "$OUT" $'\e' "plain"
    assert_not_contains "$OUT" "install done" "no trailer"
    assert_eq "$(head -n 1 <<<"$OUT")" "git-secret-guard: installed git-secret-guard $(<"$GSG_PROJECT/VERSION")" "first line as before"
}

# ^ invariant a refused global core.hooksPath prints exactly two lines after the GIT_CONFIG_GLOBAL note, nothing on stdout, no escape, nothing installed
assert_the_hooks_path_refusal_alone() {
    local want="git-secret-guard: the global core.hooksPath is set to [$LC_HOME/hooks-elsewhere]; install changes nothing and refuses.
git-secret-guard: run install --replace-hooks-path to record it, back up the directory it points to, and unset it."
    assert_rc 1 "refused without --replace-hooks-path"
    assert_eq "$(tail -n 2 <<<"$ERR")" "$want" "the refusal says why and what to run, and ends there (no trailer line)"
    assert_empty "$OUT" "nothing on stdout"
    assert_not_contains "$ERR" "$ESC" "no escape sequence"
    assert_no_file "$LC_STATE" "a refused install leaves no state"
}

test_a_refused_install_adds_no_line_in_terminal_mode() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    git_literal_config --global core.hooksPath "$LC_HOME/hooks-elsewhere" || return 1
    ui_force_terminal
    gsg install
    assert_the_hooks_path_refusal_alone
}

test_a_refused_install_in_plain_mode_has_no_trailer() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    git_literal_config --global core.hooksPath "$LC_HOME/hooks-elsewhere" || return 1
    gsg install
    assert_the_hooks_path_refusal_alone
}

test_uninstall_marks_its_removed_the_state_line_and_adds_no_line() {
    fresh_install
    ui_force_terminal
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$OUT" "$OK_ICON git-secret-guard: removed the state" "the existing final line carries the icon"
    assert_not_contains "$OUT" "uninstall done" "no trailer"
    gsg uninstall
    assert_rc 0 "second uninstall"
    assert_eq "$OUT" "$OK_ICON git-secret-guard: nothing to do, git-secret-guard is not installed" "the existing line"
}

test_unlink_and_restore_smartgit_nothing_to_do_lines_get_the_ok_icon() {
    fresh_install
    ui_force_terminal
    gsg unlink-desktop-git
    assert_rc 0 "unlink"
    assert_eq "$OUT" "$OK_ICON git-secret-guard: nothing to unlink, install has not changed anything here" "unlink"
    gsg restore-smartgit
    assert_rc 0 "restore-smartgit"
    assert_eq "$OUT" "$OK_ICON git-secret-guard: nothing to restore: git-secret-guard has not changed SmartGit" "restore-smartgit"
}

test_update_with_auto_update_off_puts_the_ok_icon_on_its_line() {
    fresh_install
    ui_force_terminal
    gsg update
    assert_rc 0 "update"
    assert_eq "$OUT" "$OK_ICON git-secret-guard: auto-update is off" "one line with the icon"
}

test_no_color_keeps_the_lifecycle_output_plain() {
    fresh_install
    ui_force_terminal
    set_env NO_COLOR=1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_not_contains "$OUT" $'\e' "no escape sequence"
    assert_not_contains "$OUT" "uninstall done" "no trailer"
}

run_file_tests
