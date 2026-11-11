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

# ^ invariant sg_linux_setup [ID [ID_LIKE]] = a Linux machine (git 2.56.0 first on PATH, os-release ID default fedora) with the Flatpak SmartGit 26.1
# ^ invariant the host git is the wrapper from gu_old_git; every path is in the sandbox, nothing under the real home
sg_linux_setup() {
    rm -f -- "$SANDBOX/smartgit.running" "$SANDBOX/smartgit.log" "$SANDBOX/flatpak.overrides" || return 1
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gu_old_git 2.56.0 || return 1
    if [ -n "${2:-}" ]; then gu_os_release "ID=${1:-fedora}" "ID_LIKE=\"$2\"" || return 1; else gu_os_release "ID=${1:-fedora}" || return 1; fi
    sg_standins || return 1
    : >"$SANDBOX/flatpak.installed" || return 1
    SG_SETTINGS="$LC_HOME/.var/app/com.syntevo.SmartGit/config/smartgit/26.1"
    SG_PREFS="$SG_SETTINGS/preferences.yml"
    SG_BACKUPS="$LC_STATE/smartgit"
    sg_make_prefs "$SG_PREFS" /app || return 1
    mkdir -p -- "$SANDBOX/root" || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root"
    set_env PATH="$SANDBOX/pathbin:$SANDBOX/lfsmissing:$TEST_BASE_PATH"
}

test_the_flatpak_setup_is_refused_by_design_and_prints_the_four_manual_steps() {
    local h
    sg_linux_setup || return 1
    h="$(sg_hash "$SG_PREFS")"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "the Flatpak is refused"
    assert_contains "$ERR" "the Flatpak settings are not edited by this tool" "says so"
    assert_contains "$ERR" "1. sudo flatpak override --system --talk-name=org.freedesktop.Flatpak com.syntevo.SmartGit" "step 1 by hand"
    assert_contains "$ERR" "2. create the wrapper" "step 2 by hand"
    assert_contains "$ERR" "3. add -Djava.io.tmpdir=" "step 3 by hand"
    assert_contains "$ERR" "4. in SmartGit choose Other Git Executable" "step 4 by hand"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "the preferences are byte-identical"
    assert_no_file "$SG_BACKUPS" "no backup or manifest"
    assert_no_file "$LC_HOME/.local/share/smartgit" "no wrapper directory"
    assert_not_contains "$(sg_log)" "override --system" "flatpak override did not run"
    assert_not_contains "$(gu_log)" "install -y" "no package was installed"
    gsg status
    assert_contains "$OUT" "flatpak com.syntevo.SmartGit (SmartGit 26.1.056)" "status still lists the Flatpak install"
}

# ^ invariant sg_lfs_plan_run [install] runs smartgit_lfs_plan (and smartgit_lfs_install_pkg with the argument) in the gu_run shell on the sandbox git
# shellcheck disable=SC2016
sg_lfs_plan_run() {
    gu_run 'for l in smartgit smartgit_report smartgit_offer smartgit_lfs smartgit_apply; do source "$GSG_ROOT/lib/$l.sh" || exit 9; done
paths_init || exit 9
GSG_GIT="$1"; INSTALL_TIMEOUT_BIN="$(type -P timeout)"; gitup_select || exit 8
smartgit_lfs_plan || exit 1
if [ "$2" = install ]; then smartgit_lfs_install_pkg || exit 1; fi' "$SANDBOX/pathbin/git" "${1:-plan}"
}

test_dnf_plans_and_runs_the_install_when_a_repository_offers_git_lfs() {
    sg_linux_setup rocky "rhel centos fedora" || return 1
    printf '3.4.1\n' >"$SANDBOX/dnf.candidate" || return 1
    sg_lfs_plan_run install
    assert_rc 0 "a repository offers git-lfs"
    assert_contains "$OUT" "as root: $SANDBOX/pathbin/dnf install -y git-lfs" "the plan names the root command with its full path"
    assert_contains "$(gu_log)" "repoquery" "dnf was asked"
    assert_contains "$(gu_log)" "sudo -- $SANDBOX/pathbin/dnf install -y git-lfs" "the install ran through sudo"
}

test_dnf_refuses_naming_epel_as_a_likely_source_and_enables_no_repository_when_none_offers_git_lfs() {
    sg_linux_setup rocky "rhel centos fedora" || return 1
    sg_lfs_plan_run
    assert_rc 1 "no repository offers git-lfs"
    assert_contains "$ERR" "no enabled dnf repository offers git-lfs" "says so"
    assert_contains "$ERR" "EPEL" "names EPEL as a likely source"
    assert_contains "$ERR" "enables no repository" "and that nothing is enabled"
    assert_not_contains "$(gu_log)" "install -y" "no package install ran"
    assert_not_contains "$(gu_log)" "enablerepo" "no repository was enabled"
}

test_a_failing_dnf_repoquery_is_its_own_refusal_not_an_answer_of_none() {
    sg_linux_setup rocky "rhel centos fedora" || return 1
    printf 'repoquery' >"$SANDBOX/dnf.fail" || return 1
    sg_lfs_plan_run
    assert_rc 1 "the query failed"
    assert_contains "$ERR" "the dnf repoquery for git-lfs failed" "says the query failed"
    assert_not_contains "$ERR" "no enabled dnf repository" "and does not claim none offers it"
}

test_apt_installs_git_lfs_non_interactively_on_ubuntu() {
    sg_linux_setup ubuntu || return 1
    sg_lfs_plan_run install
    assert_rc 0 "apt installs git-lfs"
    assert_contains "$(gu_log)" "install -y git-lfs | ppa-files=0 ppa-keys=0 frontend=noninteractive" "with -y and the non-interactive frontend"
}

test_git_lfs_only_outside_the_path_smartgit_gives_git_is_refused_with_the_instruction() {
    local h
    sg_setup || return 1
    sg_real_tools || return 1
    h="$(sg_hash "$SG_PREFS")"
    set_env GSG_SMARTGIT_LAUNCH_PATH="$SANDBOX/pathbin"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "git-lfs is installed where SmartGit's git cannot see it"
    assert_contains "$(gm_calls)" "install git-lfs" "brew installed it"
    assert_contains "$ERR" "in the environment SmartGit gives git" "says whose environment was checked"
    assert_contains "$ERR" "absolute paths in the filter.lfs.* settings" "gives SmartGit's own advice"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "the preferences are byte-identical"
    assert_eq "$(sg_count_in "$SG_BACKUPS" manifest)" 0 "no manifest"
}

test_smartgit_started_after_the_plan_is_refused_right_before_the_edit() {
    local h
    sg_setup || return 1
    sg_real_tools || return 1
    sg_lfs_present || return 1
    h="$(sg_hash "$SG_PREFS")"
    printf '2' >"$SANDBOX/smartgit.running.after" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "SmartGit started meanwhile"
    assert_contains "$ERR" "started meanwhile" "says so"
    assert_contains "$ERR" "nothing was restored" "no file of SmartGit had been changed"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "the preferences are byte-identical"
    assert_eq "$(sg_count_in "$SG_BACKUPS" 'manifest|preferences')" 0 "the pending manifest and the backup were dropped"
}

test_a_symlinked_settings_directory_is_refused() {
    local h
    sg_setup || return 1
    mv -- "$SG_SETTINGS" "$SANDBOX/real-26.1" && ln -s "$SANDBOX/real-26.1" "$SG_SETTINGS" || return 1
    h="$(sg_hash "$SANDBOX/real-26.1/preferences.yml")"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "the settings directory is a symbolic link"
    assert_contains "$ERR" "is a symbolic link" "says so"
    assert_eq "$(sg_hash "$SANDBOX/real-26.1/preferences.yml")" "$h" "the real preferences are untouched"
    assert_no_file "$SG_BACKUPS" "nothing was written"
}

test_a_kept_backup_is_not_overwritten_by_the_next_run() {
    local bk kept h_bk
    sg_configure || return 1
    assert_rc 0 "configure"
    printf '%s\n' "$(sed 's|^  executable: .*|  executable: /usr/bin/git|' "$SG_PREFS")" >"$SANDBOX/prefs.user" || return 1
    cp -- "$SANDBOX/prefs.user" "$SG_PREFS" || return 1
    gsg restore-smartgit
    assert_rc 0 "restore-smartgit leaves the user's value"
    bk="$(echo "$SG_BACKUPS"/*.preferences.yml)"
    h_bk="$(sg_hash "$bk")"
    printf '%s\n' "$(sed 's|maxCount: 3|maxCount: 4|' "$SANDBOX/prefs.orig")" >"$SG_PREFS" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "configure again"
    assert_contains "$OUT" "the earlier backup was kept as" "says where the old backup went"
    kept="$(echo "$SG_BACKUPS"/*.kept-*)"
    assert_eq "$(sg_hash "$kept")" "$h_bk" "the kept backup is byte-identical to what it was"
}

test_template_hooks_cannot_break_the_verify_commits() {
    sg_setup || return 1
    sg_real_tools || return 1
    mkdir -p -- "$SANDBOX/tpl/hooks" && printf '#!/bin/sh\nexit 1\n' >"$SANDBOX/tpl/hooks/pre-commit" && chmod 755 "$SANDBOX/tpl/hooks/pre-commit" || return 1
    gitx config --global init.templateDir "$SANDBOX/tpl" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "a failing template hook does not reach the scratch repository"
}

# shellcheck disable=SC2016
test_smartgit_bounded_uses_the_doctor_time_bound_only_when_it_is_set() {
    sg_setup || return 1
    gm_stub "$SANDBOX/timeoutlog" 'printf "%s\n" "$*" >>"${0%/*}/timeout.log"; shift 3; exec "$@"' || return 1
    gu_run 'source "$GSG_ROOT/lib/smartgit.sh" || exit 9; DR_LIMIT=7; TIMEOUT_BIN="$1"; smartgit_bounded echo bounded' "$SANDBOX/timeoutlog"
    assert_rc 0 "bounded run"
    assert_contains "$OUT" "bounded" "the command ran"
    assert_contains "$(<"$SANDBOX/timeout.log")" "-k 5 7 echo bounded" "through timeout with the doctor limit"
    rm -f -- "$SANDBOX/timeout.log" || return 1
    gu_run 'source "$GSG_ROOT/lib/smartgit.sh" || exit 9; TIMEOUT_BIN="$1"; smartgit_bounded echo plain' "$SANDBOX/timeoutlog"
    assert_contains "$OUT" "plain" "without the limit the command still runs"
    assert_no_file "$SANDBOX/timeout.log" "and no timeout is used"
}

test_uninstall_stops_before_changing_anything_while_smartgit_runs() {
    sg_configure || return 1
    assert_rc 0 "configure"
    sg_running || return 1
    gsg uninstall
    assert_rc 1 "SmartGit is running"
    assert_contains "$ERR" "uninstall stopped before removing anything else" "says nothing else was removed"
    assert_contains "$ERR" "SmartGit is running" "and why"
    assert_eq "$(gitx config --global --get hook.git-secret-guard.event)" pre-commit "the hook config is still there"
    assert_file "$LC_STATE/state" "the state is still there"
    assert_file "$LC_BIN/git-secret-guard" "and so is the CLI link, to run again"
    rm -f -- "$SANDBOX/smartgit.running" || return 1
    gsg uninstall
    assert_rc 0 "uninstall once SmartGit is closed"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "SmartGit is back on its original setting"
}

# ^ invariant SG_STOP_FIRST stops sg_interrupt_run at the first move whose arguments match; SG_STOP_SECOND lets one such move pass and stops at the next
SG_STOP_FIRST=0
SG_STOP_SECOND=1

# ^ invariant sg_interrupt_setup = a Mac with SmartGit on its bundled git, the real scanners, a working git-lfs and the original preferences copied
sg_interrupt_setup() {
    sg_setup || return 1
    sg_real_tools || return 1
    sg_lfs_present || return 1
    cp -- "$SG_PREFS" "$SANDBOX/prefs.orig" || return 1
}

# ^ invariant sg_count_in DIR REGEX = how many names in DIR match REGEX; 0 when DIR does not exist
sg_count_in() { { ls -A "$1" 2>/dev/null || true; } | grep -c -E "$2" || true; }

# ^ invariant sg_rerun_ok = the plain install --configure-smartgit again, without a terminal, and it must succeed
sg_rerun_ok() {
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "the rerun completes"
}

# ^ invariant sg_restore_ok = restore-smartgit, and it must succeed
sg_restore_ok() {
    gsg restore-smartgit
    assert_rc 0 "restore-smartgit"
}

# ^ invariant sg_assert_edit_in_place = the preferences name the sandbox git as the Git Executable
sg_assert_edit_in_place() {
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$SANDBOX/pathbin/git" "the edit is in place"
}

test_an_interrupt_before_the_pending_manifest_leaves_the_preferences_untouched_and_a_rerun_completes() {
    sg_interrupt_setup || return 1
    sg_interrupt_run .manifest "$SG_STOP_FIRST" TERM "$GSG_PROJECT/bin/git-secret-guard" install --configure-smartgit || return 1
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences were not touched"
    assert_eq "$(sg_count_in "$SG_BACKUPS" '\.manifest$')" 0 "no manifest claims an edit"
    sg_rerun_ok
    sg_assert_edit_in_place
    assert_eq "$(sg_count_in "$SG_BACKUPS" '\.manifest$')" 1 "one final manifest"
    assert_eq "$(sg_count_in "$SG_BACKUPS" '^manifest\.')" 0 "the temp file of the stopped run is gone"
}

test_an_interrupt_before_the_preferences_rename_is_undone_by_restore_and_completed_by_a_rerun() {
    local temp_re='^\.preferences\.yml\.gsg\.'
    sg_interrupt_setup || return 1
    sg_interrupt_run preferences.yml "$SG_STOP_FIRST" TERM "$GSG_PROJECT/bin/git-secret-guard" install --configure-smartgit || return 1
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are still the original"
    assert_contains "$(cat "$SG_BACKUPS"/*.manifest)" "status=pending" "the manifest says the change is pending"
    assert_eq "$(sg_count_in "$SG_SETTINGS" "$temp_re")" 1 "the temp file of the edit was left"
    sg_restore_ok
    assert_contains "$OUT$ERR" "already the original" "it sees nothing to undo"
    sg_rerun_ok
    sg_assert_edit_in_place
    assert_eq "$(sg_count_in "$SG_SETTINGS" "$temp_re")" 0 "the temp file is gone"
}

test_an_interrupt_before_the_final_manifest_is_undone_by_restore_and_completed_by_a_rerun() {
    sg_interrupt_setup || return 1
    sg_interrupt_run .manifest "$SG_STOP_SECOND" TERM "$GSG_PROJECT/bin/git-secret-guard" install --configure-smartgit || return 1
    sg_assert_edit_in_place
    assert_contains "$(cat "$SG_BACKUPS"/*.manifest)" "status=pending" "the manifest still says pending"
    sg_restore_ok
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are the original again"
    sg_rerun_ok
    assert_contains "$(cat "$SG_BACKUPS"/*.manifest)" "status=final" "the manifest is final"
}

test_an_interrupted_git_lfs_record_leaves_a_temp_file_and_no_filter_and_restore_smartgit_clears_it() {
    sg_interrupt_setup || return 1
    sg_interrupt_run lfs.record "$SG_STOP_FIRST" TERM "$GSG_PROJECT/bin/git-secret-guard" install --configure-smartgit || return 1
    assert_eq "$(sg_count_in "$SG_BACKUPS" '^lfs-tmp\.')" 1 "the temp file of the record was left"
    assert_eq "$(gitx config --global --get-regexp '^filter\.lfs\.' | wc -l | tr -d ' ')" 0 "no filter was written yet"
    sg_restore_ok
    assert_no_file "$SG_BACKUPS" "the temp file and the state directory are gone"
}

run_file_tests
