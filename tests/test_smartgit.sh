#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119,SC2120
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"
# shellcheck source=tests/gitup_macos.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup_macos.sh"
# shellcheck source=tests/smartgit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/smartgit.sh"

# ^ external the macOS flow drives Homebrew and a macOS bundle; Windows has its own detection and no recorded settings key
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the SmartGit macOS flow"; fi
GU_PTY_BSD=1

# ^ invariant sg_installed = sg_setup followed by a plain install (fixture scanners); the preferences file is untouched by it
sg_installed() {
    sg_setup "$@" || return 1
    gsg install </dev/null
    assert_rc 0 "plain install on the SmartGit machine"
}

# ^ invariant sg_untouched HASH LABEL = the preferences file has the hash it had and no backup directory exists
sg_untouched() {
    assert_eq "$(sg_hash "$SG_PREFS")" "$1" "$2: the preferences file is byte-identical"
    assert_no_file "$SG_BACKUPS" "$2: no backup or manifest was written"
}

sg_doctor() {
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
}

# ^ invariant sg_target_check GIT runs the target check of the product on one git in the shell of gu_run
sg_target_check() {
    gu_run 'for l in smartgit smartgit_report smartgit_offer; do source "$GSG_ROOT/lib/$l.sh" || exit 9; done; paths_init; smartgit_check_target "$1"' "$1"
}

test_status_reports_a_smartgit_on_its_bundled_git_older_than_2_54_as_a_problem_with_the_command() {
    sg_installed || return 1
    gsg status
    assert_rc 1 "status with a SmartGit that commits with git 2.53.0"
    assert_contains "$OUT" "SmartGit install: " "the install is listed"
    assert_contains "$OUT" "$SG_APP (SmartGit 26.1.056)" "with its path and version"
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): bundled git, git 2.53.0" "the settings directory and the bundled git version read from the bundle"
    assert_contains "$OUT" "commits are NOT scanned MISMATCH: run: git-secret-guard install --configure-smartgit" "names the fix command"
}

test_doctor_reports_that_smartgit_bundled_git_as_a_problem_naming_the_fix_command() {
    sg_installed || return 1
    sg_doctor
    assert_rc 1 "doctor with a SmartGit on git 2.53.0"
    assert_contains "$OUT" "PROBLEM  SmartGit 26.1 ($SG_SETTINGS): Git Executable is the bundled git 2.53.0" "a PROBLEM for the old bundled git"
    assert_contains "$OUT" "run: git-secret-guard install --configure-smartgit" "with the fix command"
}

test_a_smartgit_settings_dir_without_any_installation_is_a_warning_not_a_problem() {
    sg_installed || return 1
    rm -rf -- "$SG_APP" || return 1
    sg_doctor
    assert_rc 0 "no installation found: the settings directory is a leftover"
    assert_contains "$OUT" "WARNING  SmartGit 26.1 ($SG_SETTINGS)" "reported as a warning"
}

test_status_and_doctor_say_nothing_about_smartgit_when_it_is_not_there() {
    sg_installed || return 1
    rm -rf -- "$SG_APP" "$LC_HOME/Library" || return 1
    gsg status
    assert_not_contains "$OUT$ERR" "SmartGit" "status is silent"
    sg_doctor
    assert_not_contains "$OUT$ERR" "SmartGit" "doctor is silent"
}

test_a_new_major_version_directory_is_reported_as_not_configured_with_the_command() {
    sg_installed || return 1
    mkdir -p -- "$LC_HOME/Library/Preferences/SmartGit/27.0" || return 1
    gsg status
    assert_contains "$OUT" "SmartGit settings: $LC_HOME/Library/Preferences/SmartGit/27.0 (27.0): no preferences.yml yet" "an empty new major directory is listed"
    sg_doctor
    assert_not_contains "$OUT" "PROBLEM  SmartGit 27.0" "a directory without preferences is nothing to configure yet"
}

test_install_without_the_flag_and_without_a_terminal_prints_the_hint_and_changes_nothing() {
    local h
    sg_setup || return 1
    h="$(sg_hash "$SG_PREFS")"
    gsg install </dev/null
    assert_rc 0 "install is not refused because of SmartGit"
    assert_contains "$OUT" "SmartGit: found $SG_APP (SmartGit 26.1.056); it commits with its bundled git 2.53.0, so its commits are not scanned" "the hint names the bundled git"
    assert_contains "$OUT" "run: git-secret-guard install --configure-smartgit" "and the command"
    assert_not_contains "$OUT$ERR" "[y/N]" "no prompt without a terminal"
    sg_untouched "$h" "hint only"
}

test_install_asks_at_a_terminal_and_a_no_changes_nothing() {
    local h
    sg_setup || return 1
    h="$(sg_hash "$SG_PREFS")"
    gsg_pty $'n\n' install
    assert_rc 0 "install with a no at the SmartGit question"
    assert_contains "$OUT" "SmartGit plan" "the plan is printed before the question"
    assert_contains "$OUT" "[y/N]" "the question was asked"
    sg_untouched "$h" "answer no"
}

test_a_running_smartgit_refuses_before_any_change() {
    local h
    sg_installed || return 1
    h="$(sg_hash "$SG_PREFS")"
    sg_running || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "SmartGit is running"
    assert_contains "$ERR" "SmartGit is running" "says so"
    assert_contains "$ERR" "Repository, Exit" "tells the user how to exit it"
    assert_contains "$ERR" "SmartGit was not changed" "claims nothing was changed"
    sg_untouched "$h" "running"
}

test_an_unrecorded_major_version_refuses_and_prints_the_manual_steps() {
    local h
    sg_installed || return 1
    mv -- "$SG_SETTINGS" "$LC_HOME/Library/Preferences/SmartGit/27.0" || return 1
    SG_PREFS="$LC_HOME/Library/Preferences/SmartGit/27.0/preferences.yml"
    h="$(sg_hash "$SG_PREFS")"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "SmartGit 27.0 was never recorded"
    assert_contains "$ERR" "was not recorded" "says the version is unknown to this tool"
    assert_contains "$ERR" "Other Git Executable" "prints the manual step"
    assert_contains "$ERR" "docs/smartgit.md" "points at the manual steps"
    sg_untouched "$h" "unrecorded major"
}

test_a_preferences_file_without_the_recorded_shape_is_refused() {
    local h
    sg_installed || return 1
    grep -v '^  executable: ' "$SG_PREFS" >"$SANDBOX/prefs.broken" || return 1
    cp -- "$SANDBOX/prefs.broken" "$SG_PREFS" || return 1
    h="$(sg_hash "$SG_PREFS")"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "no executable: line in the git: block"
    assert_contains "$ERR" "does not have the recorded shape" "says so"
    assert_contains "$ERR" "Other Git Executable" "and prints the manual step"
    sg_untouched "$h" "bad shape"
}

test_a_symlinked_preferences_file_is_refused() {
    local h
    sg_installed || return 1
    cp -- "$SG_PREFS" "$SANDBOX/real-prefs.yml" || return 1
    rm -f -- "$SG_PREFS" && ln -s "$SANDBOX/real-prefs.yml" "$SG_PREFS" || return 1
    h="$(sg_hash "$SANDBOX/real-prefs.yml")"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "a symlink"
    assert_contains "$ERR" "is a symbolic link" "says so"
    assert_eq "$(sg_hash "$SANDBOX/real-prefs.yml")" "$h" "the target is untouched"
    assert_no_file "$SG_BACKUPS" "nothing written"
}

test_a_target_git_that_is_older_than_2_54_or_does_not_run_is_refused() {
    local h
    sg_installed || return 1
    h="$(sg_hash "$SG_PREFS")"
    gm_stub "$SANDBOX/oldgit" 'if [ "$1" = --version ]; then echo "git version 2.53.0"; exit 0; fi; exit 1' || return 1
    gm_stub "$SANDBOX/deadgit" 'exit 127' || return 1
    sg_target_check "$SANDBOX/oldgit"
    assert_rc 1 "git 2.53.0 as the target"
    assert_contains "$ERR" "is git 2.53.0" "names the version"
    assert_contains "$ERR" "older than 2.54" "and the floor"
    sg_untouched "$h" "old target"
    sg_target_check "$SANDBOX/deadgit"
    assert_rc 1 "a git that does not run"
    assert_contains "$ERR" "does not run" "says so"
    sg_untouched "$h" "dead target"
}

# ^ invariant sg_configure = sg_setup, the real scanners, a copy of the original preferences in $SANDBOX/prefs.orig,
# ^ invariant followed by install --configure-smartgit without a terminal
sg_configure() {
    sg_setup "$@" || return 1
    sg_real_tools || return 1
    cp -- "$SG_PREFS" "$SANDBOX/prefs.orig" || return 1
    gsg install --configure-smartgit </dev/null
}

test_configure_smartgit_changes_only_the_two_executable_lines_and_leaves_every_other_byte() {
    local target
    sg_configure || return 1
    assert_rc 0 "install --configure-smartgit on a Mac with SmartGit on its bundled git"
    target="$SANDBOX/pathbin/git"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$target" "executable: is the git in use"
    assert_eq "$(sg_git_value executable.absolute "$SG_PREFS")" "$target" "executable.absolute: is the git in use"
    assert_eq "$(sg_others "$SG_PREFS")" "$(sg_others "$SANDBOX/prefs.orig")" "every other line is byte for byte the same"
    assert_eq "$(wc -l <"$SG_PREFS")" "$(wc -l <"$SANDBOX/prefs.orig")" "no line was added or removed"
    assert_eq "$(stat -c %a "$SG_PREFS")" 600 "the mode stays 0600"
    assert_contains "$OUT" "SmartGit plan" "the plan was printed"
    assert_contains "$OUT" "checked through $target: git lfs works, a fake-token commit was blocked and a clean commit printed the summary line" "the verify step ran"
    assert_contains "$OUT" "start SmartGit again" "tells the user to restart SmartGit"
}

test_the_backup_and_manifest_are_written_before_the_edit_and_hold_the_original() {
    local mf bk
    sg_configure || return 1
    assert_rc 0 "configure"
    mf="$(echo "$SG_BACKUPS"/*.manifest)"
    bk="$(echo "$SG_BACKUPS"/*.preferences.yml)"
    assert_file "$mf" "a manifest exists"
    assert_eq "$(sg_hash "$bk")" "$(sg_hash "$SANDBOX/prefs.orig")" "the backup is the original file"
    assert_contains "$(<"$mf")" "status=final" "the manifest is final"
    assert_contains "$(<"$mf")" "orig_executable=\${smartgit.install}/git/bin/git" "it names the original setting"
    assert_contains "$(<"$mf")" "new_executable=$SANDBOX/pathbin/git" "and the new one"
    assert_eq "$(stat -c %a "$bk")" 600 "the backup is private"
}

test_git_lfs_is_installed_with_brew_as_the_user_and_recorded_when_it_is_missing() {
    sg_configure || return 1
    assert_rc 0 "configure with Git LFS missing"
    assert_contains "$(gm_calls)" "install git-lfs" "brew install git-lfs ran"
    assert_not_contains "$(gu_log)" "sudo" "no sudo ran"
    assert_contains "$OUT" "git lfs version fails through" "the plan said why"
    assert_eq "$(gitx config --global --get filter.lfs.required)" true "git lfs install wrote the filter"
    assert_file "$SG_BACKUPS/lfs.record" "and recorded that it added it"
}

test_git_lfs_present_installs_nothing_and_still_writes_the_filter_when_none_exists() {
    sg_setup || return 1
    sg_real_tools || return 1
    sg_lfs_present || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "configure with Git LFS present"
    assert_not_contains "$(gm_calls)" "git-lfs" "brew was not asked for git-lfs"
    assert_contains "$OUT" "nothing is installed" "the plan said so"
    assert_eq "$(gitx config --global --get filter.lfs.required)" true "the filter was written because none existed"
}

test_a_failing_brew_install_of_git_lfs_changes_nothing_in_smartgit() {
    local h
    sg_setup || return 1
    sg_real_tools || return 1
    h="$(sg_hash "$SG_PREFS")"
    printf 'git-lfs' >"$SANDBOX/brew.failon" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "brew install git-lfs failed"
    assert_contains "$ERR" "brew install git-lfs failed" "says so"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "the preferences are byte-identical"
    assert_no_file "$SG_BACKUPS/lfs.record" "no LFS record"
}

test_a_failed_verify_restores_the_original_preferences_and_says_what_was_changed() {
    local h
    sg_setup || return 1
    h="$(sg_hash "$SG_PREFS")"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "the fixture scanners cannot pass the verify commit"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "the preferences are byte-identical to the original again"
    assert_contains "$ERR" "SmartGit was restored from its backup" "says the restore happened"
    assert_contains "$ERR" "Homebrew install of git-lfs" "and names the change that stays"
}

test_a_second_configure_run_reports_nothing_to_change() {
    sg_configure || return 1
    assert_rc 0 "first configure"
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "second configure"
    assert_contains "$OUT" "nothing to change" "nothing to do the second time"
}

test_an_interrupted_state_is_finished_by_a_rerun() {
    local mf bk
    sg_configure || return 1
    assert_rc 0 "configure"
    mf="$(echo "$SG_BACKUPS"/*.manifest)"
    bk="$(echo "$SG_BACKUPS"/*.preferences.yml)"
    cp -- "$bk" "$SG_PREFS" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "rerun after the file went back to the original while the manifest stayed"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$SANDBOX/pathbin/git" "the edit is in place again"
    assert_file "$mf" "one manifest"
}

test_restore_smartgit_puts_the_original_back_byte_for_byte() {
    sg_configure || return 1
    assert_rc 0 "configure"
    gsg restore-smartgit
    assert_rc 0 "restore-smartgit"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are the original"
    assert_no_file "$SG_BACKUPS" "the manifest and backup are gone"
    gsg restore-smartgit
    assert_rc 0 "restore again"
    assert_contains "$OUT" "nothing to restore" "says nothing to restore"
}

test_restore_smartgit_leaves_a_value_the_user_changed_since_and_says_so() {
    sg_configure || return 1
    assert_rc 0 "configure"
    printf '%s\n' "$(sed 's|^  executable: .*|  executable: /usr/bin/git|' "$SG_PREFS")" >"$SANDBOX/prefs.user" || return 1
    cp -- "$SANDBOX/prefs.user" "$SG_PREFS" || return 1
    gsg restore-smartgit
    assert_rc 0 "restore-smartgit"
    assert_contains "$OUT" "was changed after this tool set it" "reports the user's change"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" /usr/bin/git "and leaves it"
}

test_restore_smartgit_stops_when_the_backup_does_not_match_the_manifest() {
    local bk
    sg_configure || return 1
    assert_rc 0 "configure"
    bk="$(echo "$SG_BACKUPS"/*.preferences.yml)"
    printf 'tampered\n' >>"$bk" || return 1
    gsg restore-smartgit
    assert_rc 1 "a backup that does not match"
    assert_contains "$ERR" "does not match the manifest" "says so"
    assert_contains "$ERR" "by hand" "prints the by-hand step"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$SANDBOX/pathbin/git" "the preferences were not touched"
}

test_restore_smartgit_refuses_while_smartgit_runs() {
    sg_configure || return 1
    assert_rc 0 "configure"
    sg_running || return 1
    gsg restore-smartgit
    assert_rc 1 "SmartGit is running"
    assert_contains "$ERR" "SmartGit is running" "says so"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$SANDBOX/pathbin/git" "nothing changed"
}

test_uninstall_restores_smartgit_and_removes_only_the_filter_this_tool_added() {
    sg_configure || return 1
    assert_rc 0 "configure"
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "SmartGit is back on its original setting"
    assert_eq "$(gitx config --global --get-regexp '^filter\.lfs\.' | wc -l | tr -d ' ')" 0 "the filter that git lfs install added is gone"
    assert_no_file "$SG_BACKUPS" "no manifest or backup is left"
}

test_a_filter_that_existed_before_is_never_removed_by_the_undo() {
    sg_setup || return 1
    sg_real_tools || return 1
    sg_lfs_present || return 1
    gitx config --global filter.lfs.required true || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "configure"
    gsg restore-smartgit
    assert_rc 0 "restore"
    assert_eq "$(gitx config --global --get filter.lfs.required)" true "the user's own filter stays"
}

# ^ invariant sg_flatpak_setup [ID [ID_LIKE]] = a Linux machine (git 2.56.0 first on PATH, os-release ID=ID default fedora)
# ^ invariant with the Flatpak SmartGit 26.1 on its bundled git
# ^ invariant the host git is the wrapper from gu_old_git; the system override, wrapper and vmoptions live in the sandbox, nothing under the real home
sg_flatpak_setup() {
    local base
    rm -f -- "$SANDBOX/smartgit.running" "$SANDBOX/smartgit.log" "$SANDBOX/flatpak.overrides" || return 1
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gu_old_git 2.56.0 || return 1
    if [ -n "${2:-}" ]; then gu_os_release "ID=${1:-fedora}" "ID_LIKE=\"$2\"" || return 1; else gu_os_release "ID=${1:-fedora}" || return 1; fi
    sg_standins || return 1
    : >"$SANDBOX/flatpak.installed" || return 1
    base="$LC_HOME/.var/app/com.syntevo.SmartGit/config/smartgit"
    SG_SETTINGS="$base/26.1"
    SG_PREFS="$SG_SETTINGS/preferences.yml"
    SG_BACKUPS="$LC_STATE/smartgit"
    SG_WRAPPER="$LC_HOME/.local/share/smartgit/host-bin/git"
    SG_VMOPTS="$base/smartgit.vmoptions"
    sg_make_prefs "$SG_PREFS" /app || return 1
    printf -- '-Xmx1g\n' >"$SG_VMOPTS" || return 1
    cp -- "$SG_PREFS" "$SANDBOX/prefs.orig" || return 1
    mkdir -p -- "$SANDBOX/root" || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root"
    set_env PATH="$SANDBOX/pathbin:$SANDBOX/lfsmissing:$TEST_BASE_PATH"
}

test_the_flatpak_setup_needs_its_own_consent_for_the_sandbox_and_changes_nothing_without_it() {
    local h
    sg_flatpak_setup || return 1
    h="$(sg_hash "$SG_PREFS")"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "--configure-smartgit alone does not remove the sandbox"
    assert_contains "$OUT" "1. the sandbox of SmartGit is removed" "the plan names the step"
    assert_contains "$OUT" "as root: $SANDBOX/pathbin/flatpak override --system --talk-name=org.freedesktop.Flatpak com.syntevo.SmartGit" "with the full path of the root command"
    assert_contains "$ERR" "there was no consent to remove the sandbox" "says why nothing was done"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "the preferences are byte-identical"
    assert_no_file "$LC_HOME/.local/share/smartgit/host-bin/git" "no wrapper"
    assert_not_contains "$(sg_log)" "override --system --talk-name" "flatpak override did not run"
}

test_the_four_flatpak_steps_run_as_one_unit_with_the_separate_flag() {
    local wrapper vm
    sg_flatpak_setup || return 1
    wrapper="$SG_WRAPPER" vm="$SG_VMOPTS"
    sg_real_tools || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "the Flatpak setup"
    assert_contains "$(<"$SANDBOX/flatpak.overrides")" "org.freedesktop.Flatpak=talk" "step 1: the override is in place"
    assert_contains "$(sed -n 2p "$wrapper")" "git-secret-guard: written by install" "step 2: the wrapper carries our marker"
    assert_eq "$(stat -c %a "$wrapper")" 755 "and is executable"
    assert_eq "$(grep -c 'java.io.tmpdir' "$vm")" 1 "step 3: one tmpdir line"
    assert_contains "$(<"$vm")" "-Xmx1g" "the other vmoptions line is kept"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$wrapper" "step 4: the Git Executable is the wrapper"
    assert_contains "$(gu_log)" "install -y git-lfs" "git-lfs came from dnf on the host"
    assert_contains "$(gu_log)" "sudo -- $SANDBOX/pathbin/flatpak override --system" "the override ran through sudo"
}

test_restore_smartgit_undoes_every_flatpak_step_and_keeps_the_other_vmoptions_lines() {
    local vm
    sg_flatpak_setup || return 1
    vm="$SG_VMOPTS"
    sg_real_tools || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "the Flatpak setup"
    gsg restore-smartgit
    assert_rc 0 "restore-smartgit"
    assert_no_file "$SANDBOX/flatpak.overrides" "the override is gone"
    assert_no_file "$SG_WRAPPER" "the wrapper is gone"
    assert_eq "$(<"$vm")" "-Xmx1g" "only our vmoptions line was removed"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the Git Executable is the original"
    assert_no_file "$SG_BACKUPS" "no record is left"
}

test_a_wrapper_that_is_not_ours_is_refused_and_left_alone() {
    local wrapper
    sg_flatpak_setup || return 1
    wrapper="$SG_WRAPPER"
    sg_real_tools || return 1
    mkdir -p -- "${wrapper%/*}" && printf '#!/bin/sh\necho mine\n' >"$wrapper" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 1 "a foreign wrapper"
    assert_contains "$ERR" "is not a wrapper this tool wrote" "says so"
    assert_contains "$(<"$wrapper")" "echo mine" "the file is untouched"
}

test_dnf_on_a_rhel_compatible_system_refuses_without_epel_and_never_enables_a_repository() {
    sg_flatpak_setup rocky "rhel centos fedora" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 1 "EPEL is not enabled"
    assert_contains "$ERR" "git-lfs is in EPEL" "says why"
    assert_contains "$ERR" "this tool does not enable a repository" "and that nothing was enabled"
    assert_not_contains "$(gu_log)" "install -y" "no package install ran"
    assert_not_contains "$(gu_log)" "enablerepo" "no repository was enabled"
}

test_apt_installs_git_lfs_non_interactively_on_ubuntu() {
    sg_flatpak_setup ubuntu || return 1
    sg_real_tools || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "the Flatpak setup on Ubuntu"
    assert_contains "$(gu_log)" "install -y git-lfs | ppa-files=0 ppa-keys=0 frontend=noninteractive" "git-lfs is installed with -y and the non-interactive frontend"
}

run_file_tests
