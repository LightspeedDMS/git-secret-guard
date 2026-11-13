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
# shellcheck source=tests/smartgit_linux.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/smartgit_linux.sh"

# ^ external the Linux flows use Linux paths, pgrep and the flatpak stand-in; Windows has its own detection and no recorded settings key
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the SmartGit Linux flow"; fi
GU_PTY_BSD=1

test_status_reads_the_flatpak_version_with_underscores_and_the_bundled_git_through_flatpak_run() {
    sl_flatpak_setup || return 1
    gsg install </dev/null
    gsg status
    assert_rc 1 "status with a Flatpak SmartGit on its bundled git 2.53.0"
    assert_contains "$OUT" "flatpak com.syntevo.SmartGit (SmartGit 26.1.057)" "26_1_057 is read as 26.1.057, so the install matches settings 26.1"
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): bundled git, git 2.53.0" "the bundled git is read through flatpak run"
    assert_contains "$OUT" "commits are NOT scanned MISMATCH: run: git-secret-guard install --configure-smartgit" "and names the fix"
}

test_doctor_reports_a_flatpak_on_its_old_bundled_git_as_a_problem() {
    sl_flatpak_setup || return 1
    gsg install </dev/null
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor with a Flatpak SmartGit on git 2.53.0"
    assert_contains "$OUT" "PROBLEM  SmartGit 26.1 ($SG_SETTINGS): Git Executable is the bundled git 2.53.0" "a PROBLEM now that the version is readable"
}

test_a_home_relative_executable_is_read_as_the_wrapper_and_judged_inside_the_sandbox() {
    sl_flatpak_setup linux-flatpak-26.1-byhand || return 1
    sl_hand_wrapper || return 1
    gsg install </dev/null
    gsg status
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): $SL_WRAPPER, git 2.56.0; commits are scanned" "a home-relative path is the wrapper, run inside the sandbox"
    assert_not_contains "$OUT" "unknown form" "never an executable of unknown form"
}

test_doctor_reports_a_tarball_on_its_old_bundled_git_as_a_problem() {
    sl_tarball_setup || return 1
    gsg install </dev/null
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor with a tarball SmartGit on git 2.53.0"
    assert_contains "$OUT" "PROBLEM  SmartGit 26.1 ($SG_SETTINGS): Git Executable is the bundled git 2.53.0" "the bundle's git is read on the host"
    assert_contains "$OUT" "run: git-secret-guard install --configure-smartgit" "with the fix command"
}

# ^ invariant sl_tarball_configure = a tarball SmartGit on its bundled git, the real scanners, a working git-lfs, and install --configure-smartgit after them
sl_tarball_configure() {
    sl_tarball_setup || return 1
    sg_real_tools || return 1
    sg_lfs_present || return 1
    gsg install --configure-smartgit </dev/null
}

test_configure_on_a_tarball_changes_only_the_two_executable_lines_and_verifies() {
    local target="$SANDBOX/pathbin/git"
    sl_tarball_configure || return 1
    assert_rc 0 "install --configure-smartgit on a tarball SmartGit"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$target" "executable: is the git in use"
    assert_eq "$(sg_git_value executable.absolute "$SG_PREFS")" "$target" "executable.absolute: too"
    assert_eq "$(sg_others "$SG_PREFS")" "$(sg_others "$SANDBOX/prefs.orig")" "every other line is byte for byte the same"
    assert_eq "$(stat -c %a "$SG_PREFS")" 600 "the mode stays"
    assert_contains "$(sg_log)" 'pgrep -u' "the running check looked for the user's processes"
    assert_contains "$(sg_log)" 'lib/bootloader\.jar' "by the launcher jar"
    assert_contains "$OUT" "checked through $target: git lfs works, a fake-token commit was blocked" "the verify step ran"
}

test_the_linux_launch_path_is_the_git_directory_then_usr_local_bin_usr_bin_bin() {
    sl_common || return 1
    gu_run 'source "$GSG_ROOT/lib/smartgit.sh" && source "$GSG_ROOT/lib/smartgit_lfs.sh" || exit 9
smartgit_platform() { REPLY=linux; }
unset GSG_SMARTGIT_LAUNCH_PATH; smartgit_lfs_launch_path /opt/x/bin/git'
    assert_rc 0 "an absolute git path"
    assert_eq "$OUT" "/opt/x/bin:/usr/local/bin:/usr/bin:/bin" "the git directory first, then the system directories"
}

test_restore_of_a_tarball_checks_the_linux_process_and_puts_the_original_back_byte_for_byte() {
    sl_tarball_configure || return 1
    assert_rc 0 "configure"
    rm -f -- "$SANDBOX/smartgit.log" || return 1
    sg_running || return 1
    gsg restore-smartgit
    assert_rc 1 "SmartGit is running"
    assert_contains "$ERR" "SmartGit (or another Syntevo app) of this user is running" "the restore names what the Linux check matches"
    assert_contains "$(sg_log)" 'lib/bootloader\.jar' "the restore asked for the Linux process"
    assert_not_contains "$(sg_log)" 'Contents/MacOS' "never for the macOS app"
    rm -f -- "$SANDBOX/smartgit.running" || return 1
    gsg restore-smartgit
    assert_rc 0 "restore once SmartGit is closed"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are the original byte for byte"
    assert_no_file "$SG_BACKUPS" "no manifest or backup is left"
    assert_not_contains "$OUT" "removed what this tool added" "a restore with no Flatpak record names no Flatpak step"
}

# ^ invariant sl_tarball_refused TEXT = install --configure-smartgit was refused with TEXT and nothing of SmartGit changed
sl_tarball_refused() {
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "refused"
    assert_contains "$ERR" "$1" "says why"
    assert_contains "$ERR" "SmartGit was not changed" "and that nothing changed"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are byte-identical"
    assert_no_file "$SG_BACKUPS" "no backup or manifest"
}

test_a_tarball_settings_dir_whose_setup_never_finished_is_refused() {
    sl_tarball_setup || return 1
    rm -f -- "$SG_SETTINGS/startup" || return 1
    sl_tarball_refused "SmartGit is not set up yet here (no startup file); start SmartGit once, finish its setup wizard"
}

test_a_running_tarball_smartgit_is_refused_before_any_change() {
    sl_tarball_setup || return 1
    sg_running || return 1
    sl_tarball_refused "SmartGit (or another Syntevo app) of this user is running"
}

# ^ invariant sl_lfs_missing_setup ID = a tarball SmartGit on a machine with os-release ID, the real scanners and no git-lfs SmartGit's git can find
sl_lfs_missing_setup() {
    sl_tarball_setup || return 1
    gu_os_release "ID=$1" || return 1
    sg_real_tools
}

test_git_lfs_missing_on_fedora_is_installed_with_dnf_as_root_after_the_repoquery() {
    sl_lfs_missing_setup fedora || return 1
    printf '3.7.1\n' >"$SANDBOX/dnf.candidate" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "configure with git-lfs from dnf"
    assert_contains "$OUT" "as root: $SANDBOX/pathbin/dnf install -y git-lfs" "the plan names the root command with its full path"
    assert_contains "$(gu_log)" "repoquery --available --latest-limit=1" "dnf was asked first, for available packages"
    assert_contains "$OUT" "a repository signing key import included" "the plan says dnf install -y may import a key"
    assert_contains "$(gu_log)" "sudo -- $SANDBOX/pathbin/dnf install -y git-lfs" "the install ran through sudo"
}

test_no_enabled_dnf_repository_offering_git_lfs_is_refused_and_no_repository_is_enabled() {
    sl_lfs_missing_setup fedora || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "no repository offers git-lfs"
    assert_contains "$ERR" "no enabled dnf repository offers git-lfs" "says so"
    assert_not_contains "$ERR" "EPEL" "names no repository it did not see"
    assert_not_contains "$(gu_log)" "install -y" "no package install ran"
    assert_not_contains "$(gu_log)" "enablerepo" "no repository was enabled"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are byte-identical"
}

test_a_failing_dnf_repoquery_is_its_own_refusal_not_an_answer_of_none() {
    sl_lfs_missing_setup fedora || return 1
    printf 'repoquery' >"$SANDBOX/dnf.fail" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "the query failed"
    assert_contains "$ERR" "the dnf repoquery for git-lfs failed" "says the query failed"
    assert_not_contains "$ERR" "no enabled dnf repository" "and does not claim none offers it"
}

test_git_lfs_missing_on_ubuntu_is_installed_with_apt_non_interactively() {
    sl_lfs_missing_setup ubuntu || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "configure with git-lfs from apt"
    assert_contains "$(gu_log)" "install -y git-lfs | ppa-files=0 ppa-keys=0 frontend=noninteractive" "with -y and the non-interactive frontend"
    assert_contains "$OUT" "DPkg::Lock::Timeout=" "the plan prints the same command it runs"
}

test_no_apt_candidate_for_git_lfs_is_refused_in_the_plan_before_any_install() {
    sl_lfs_missing_setup ubuntu || return 1
    printf '(none)\n' >"$SANDBOX/apt.lfs.candidate" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "no candidate"
    assert_contains "$ERR" "no apt repository offers git-lfs" "says so"
    assert_contains "$(gu_log)" "apt-cache policy git-lfs | locale=C" "apt was asked, in the C locale"
    assert_not_contains "$(gu_log)" "install -y" "no package install ran"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "the preferences are byte-identical"
}

test_a_pre_release_apt_candidate_for_git_lfs_is_refused_with_its_own_wording() {
    sl_lfs_missing_setup ubuntu || return 1
    printf '3.4.1~rc1-1\n' >"$SANDBOX/apt.lfs.candidate" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "a pre-release candidate is refused"
    assert_contains "$ERR" "apt offers git-lfs 3.4.1~rc1-1, which is not a release version" "says what apt offers"
    assert_not_contains "$ERR" "no apt repository offers git-lfs" "and does not claim none is offered"
    assert_not_contains "$(gu_log)" "install -y" "no package install ran"
}

# ^ invariant sl_flatpak_ready [FIXTURE] = the Flatpak SmartGit, a vmoptions file with one line of its own (copy in vmopts.orig), scanners, git-lfs
sl_flatpak_ready() {
    sl_flatpak_setup "$@" || return 1
    printf -- '-Xmx1024m\n' >"$SL_VMOPTS" && chmod 640 "$SL_VMOPTS" && cp -p -- "$SL_VMOPTS" "$SANDBOX/vmopts.orig" || return 1
    sg_real_tools || return 1
    sg_lfs_present
}

# ^ invariant sl_flatpak_configure [FIXTURE] = sl_flatpak_ready and install --configure-smartgit with the sandbox consent flag, without a terminal
sl_flatpak_configure() {
    sl_flatpak_ready "$@" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
}

# ^ invariant sl_flatpak_untouched MSG asserts the Flatpak and its settings are as sl_flatpak_ready left them; shared by the refusal tests
sl_flatpak_untouched() {
    assert_no_file "$SANDBOX/flatpak.override.user" "$1: no --user override"
    assert_no_file "$SL_WRAPPER" "$1: no wrapper"
    assert_eq "$(sg_hash "$SL_VMOPTS")" "$(sg_hash "$SANDBOX/vmopts.orig")" "$1: smartgit.vmoptions unchanged"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "$1: preferences.yml unchanged"
    assert_no_file "$SL_FLATPAK_RECORD" "$1: no record"
}

test_a_flatpak_run_without_a_terminal_and_without_the_flag_is_refused_with_the_manual_steps() {
    sl_flatpak_ready || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "refused"
    assert_contains "$ERR" "step 1 removes the SmartGit sandbox and needs its own yes" "says why"
    assert_contains "$ERR" "--allow-smartgit-sandbox-removal" "names the flag"
    assert_contains "$ERR" "flatpak override --user --talk-name=org.freedesktop.Flatpak $SL_APP_ID" "prints the manual steps"
    sl_flatpak_untouched "no terminal, no flag"
}

test_no_flatpak_spawn_inside_the_sandbox_is_refused_before_any_change() {
    sl_flatpak_ready || return 1
    : >"$SANDBOX/flatpak.nospawn" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 1 "refused"
    assert_contains "$ERR" "flatpak-spawn was not found inside the SmartGit sandbox" "says why"
    sl_flatpak_untouched "no flatpak-spawn"
}

test_the_flatpak_setup_applies_the_four_steps_as_one_unit() {
    sl_flatpak_configure || return 1
    assert_rc 0 "configure the Flatpak with the sandbox consent"
    assert_contains "$(cat "$SANDBOX/flatpak.override.user")" "org.freedesktop.Flatpak=talk" "1. the --user override lets SmartGit talk to flatpak"
    assert_not_contains "$(gu_log)" "sudo" "no root was needed"
    assert_eq "$(stat -c %a "$SL_WRAPPER")" 755 "2. the wrapper is executable"
    assert_contains "$(<"$SL_WRAPPER")" "$SL_WRAPPER_MARKER" "it carries our marker"
    assert_contains "$(<"$SL_WRAPPER")" "exec flatpak-spawn --host $SANDBOX/pathbin/git \"\$@\"" "it runs the checked host git by absolute path"
    assert_contains "$(<"$SL_WRAPPER")" "credential.helper=!flatpak run --command=/app/bin/smartgit.sh" "it keeps the credential helper rewrite"
    assert_eq "$(<"$SL_VMOPTS")" "$(printf -- '-Xmx1024m\n-Djava.io.tmpdir=%s' "$SL_TMPDIR")" "3. one line was added, the rest kept"
    assert_eq "$(stat -c %a "$SL_VMOPTS")" 640 "the vmoptions mode is kept"
    assert_eq "$(stat -c %a "$SL_TMPDIR")" 700 "the temp directory is private"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$SL_WRAPPER" "4. the Git Executable is the wrapper"
    assert_eq "$(sg_git_value executable.absolute "$SG_PREFS")" "$SL_WRAPPER" "both lines"
    assert_eq "$(sg_others "$SG_PREFS")" "$(sg_others "$SANDBOX/prefs.orig")" "every other line is byte for byte the same"
    assert_contains "$OUT" "then (Flatpak): the same checks run through the wrapper $SL_WRAPPER inside the SmartGit sandbox" "the plan says where the checks run"
    assert_not_contains "$OUT" "  then: git --version and git lfs version through" "a Flatpak-only plan has no host then-line"
    assert_contains "$OUT" "Git LFS: git lfs version works through $SANDBOX/pathbin/git, the git the wrapper runs; it is checked again through the wrapper inside the SmartGit sandbox" \
        "the LFS line says where it is checked for a Flatpak"
    assert_contains "$(sg_log)" "flatpak run --cwd=$SL_TMPDIR --command=$SL_WRAPPER $SL_APP_ID" "the verify pins its working directory under HOME"
    assert_contains "$OUT" "checked through the wrapper $SL_WRAPPER inside the SmartGit sandbox" "the verify ran inside the sandbox"
}

test_an_existing_temp_directory_is_planned_and_kept_as_it_is() {
    sl_flatpak_ready || return 1
    mkdir -p -- "${SL_TMPDIR%/*}" && mkdir -m 0755 -- "$SL_TMPDIR" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "configure with a temp directory already there"
    assert_contains "$OUT" "uses the existing directory $SL_TMPDIR as it is" "the plan says it is used as it is"
    assert_not_contains "$OUT" "creates that directory" "and never promises to create it"
    assert_eq "$(stat -c %a "$SL_TMPDIR")" 755 "its mode is left alone"
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore"
    assert_file "$SL_TMPDIR" "the restore keeps a directory this tool did not make"
    rmdir -- "$SL_TMPDIR"
}

test_restore_after_the_flatpak_setup_undoes_every_step_byte_for_byte() {
    sl_flatpak_configure || return 1
    assert_rc 0 "configure first"
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore-smartgit"
    assert_contains "$OUT" "removed what this tool added for the SmartGit Flatpak: the --user override, the wrapper, the smartgit.vmoptions line, the temp directory" \
        "the restore names every Flatpak step it undid"
    assert_no_file "$SANDBOX/flatpak.override.user" "1. the --user override that held only our line was reset"
    assert_no_file "$SL_WRAPPER" "2. the wrapper is gone"
    assert_no_file "${SL_WRAPPER%/*}" "with the directory made for it"
    assert_eq "$(sg_hash "$SL_VMOPTS")" "$(sg_hash "$SANDBOX/vmopts.orig")" "3. smartgit.vmoptions is byte for byte the original"
    assert_eq "$(stat -c %a "$SL_VMOPTS")" 640 "with its mode"
    assert_no_file "$SL_TMPDIR" "the temp directory is gone"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "4. preferences.yml is byte for byte the original"
    assert_no_file "$SL_FLATPAK_RECORD" "the record is gone"
}

# ^ why a read-only config directory, not a symlink; the precheck passes it (the file is safe), only the rewrite in the undo fails
test_a_partial_flatpak_undo_names_only_the_steps_really_removed_and_keeps_the_record() {
    local d h
    if [ "$(id -u)" -eq 0 ]; then skip_test "root writes into a read-only directory"; fi
    sl_flatpak_configure || return 1
    assert_rc 0 "configure first"
    d="${SL_VMOPTS%/*}"
    chmod 500 -- "$d" || return 1
    gsg restore-smartgit </dev/null
    chmod 700 -- "$d" || return 1
    assert_rc 1 "a failed vmoptions rewrite fails the restore"
    assert_contains "$OUT" "removed what this tool added for the SmartGit Flatpak: the --user override, the wrapper" \
        "the summary names the steps that were removed even though the restore failed"
    assert_not_contains "$OUT" "the smartgit.vmoptions line" "the line still in place is not claimed as removed"
    assert_not_contains "$OUT" "the temp directory" "the kept temp directory is not claimed as removed"
    assert_contains "$ERR" "cannot remove the temp directory line from $SL_VMOPTS" "the failed step says what to do by hand"
    assert_contains "$ERR" "$SL_TMPDIR was kept: the smartgit.vmoptions line still points at it" "the output says why the directory stays"
    assert_no_file "$SL_WRAPPER" "the wrapper that did go stays gone"
    assert_file "$SL_FLATPAK_RECORD" "the record is kept for a rerun"
    assert_file "$SL_TMPDIR" "the temp directory stays while the line points at it"
    h="$(grep -c -x -- "-Djava.io.tmpdir=$SL_TMPDIR" "$SL_VMOPTS")"
    assert_eq "$h" 1 "the vmoptions line is still there"
    gsg restore-smartgit </dev/null
    assert_rc 0 "a rerun after the permission is back finishes"
    assert_no_file "$SL_TMPDIR" "the rerun removes the temp directory"
    assert_no_file "$SL_FLATPAK_RECORD" "the rerun removes the record"
    h="$(grep -c -x -- "-Djava.io.tmpdir=$SL_TMPDIR" "$SL_VMOPTS" || true)"
    assert_eq "$h" 0 "the rerun removes the vmoptions line"
}

test_uninstall_after_the_flatpak_setup_names_every_flatpak_step_it_undid() {
    sl_flatpak_configure || return 1
    assert_rc 0 "configure first"
    gsg uninstall </dev/null
    assert_rc 0 "uninstall"
    assert_contains "$OUT" "removed what this tool added for the SmartGit Flatpak: the --user override, the wrapper, the smartgit.vmoptions line, the temp directory" \
        "the uninstall names every Flatpak step it undid"
    assert_no_file "$SL_WRAPPER" "the wrapper is gone"
    assert_no_file "$SL_FLATPAK_RECORD" "the record is gone"
}

test_restore_refuses_before_restoring_anything_on_a_symlinked_vmoptions_or_no_flatpak() {
    local h
    sl_flatpak_configure || return 1
    assert_rc 0 "configure first"
    h="$(sg_hash "$SG_PREFS")"
    mv -- "$SL_VMOPTS" "$SANDBOX/vmopts.real" && ln -s -- "$SANDBOX/vmopts.real" "$SL_VMOPTS" || return 1
    gsg restore-smartgit </dev/null
    assert_rc 1 "a symlinked smartgit.vmoptions refuses the restore"
    assert_contains "$ERR" "$SL_VMOPTS is a symlink" "says why"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "preferences.yml was not restored"
    assert_file "$SL_FLATPAK_RECORD" "the record is kept"
    assert_file "$SANDBOX/flatpak.override.user" "the override is kept"
    rm -f -- "$SL_VMOPTS" && mv -- "$SANDBOX/vmopts.real" "$SL_VMOPTS" || return 1
    mv -- "$SANDBOX/pathbin/flatpak" "$SANDBOX/flatpak.aside" || return 1
    gsg restore-smartgit </dev/null
    assert_rc 1 "no flatpak command refuses the restore"
    assert_contains "$ERR" "no flatpak command" "says why"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "preferences.yml still not restored"
    assert_file "$SL_FLATPAK_RECORD" "the record is still kept"
    assert_file "$SANDBOX/flatpak.override.user" "the override is still kept"
    mv -- "$SANDBOX/flatpak.aside" "$SANDBOX/pathbin/flatpak" || return 1
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore once both are fixed"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "preferences.yml is the original"
}

test_a_talk_permission_already_in_the_user_override_is_left_alone_by_install_and_restore() {
    sl_flatpak_ready || return 1
    printf '[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n' >"$SANDBOX/flatpak.override.user" || return 1
    cp -- "$SANDBOX/flatpak.override.user" "$SANDBOX/override.orig" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "configure"
    assert_contains "$(<"$SL_FLATPAK_RECORD")" "override=no" "the permission is not recorded as ours"
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore"
    assert_eq "$(sg_hash "$SANDBOX/flatpak.override.user")" "$(sg_hash "$SANDBOX/override.orig")" "the user's override is untouched"
}

test_a_system_override_with_the_permission_is_not_recorded_as_ours() {
    sl_flatpak_ready || return 1
    printf '[Session Bus Policy]\norg.freedesktop.Flatpak=talk\n' >"$SANDBOX/flatpak.override.system" || return 1
    cp -- "$SANDBOX/flatpak.override.system" "$SANDBOX/override.orig" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "configure"
    assert_contains "$OUT" "that override is not ours and is left alone" "says so"
    assert_no_file "$SANDBOX/flatpak.override.user" "no --user override was added"
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore"
    assert_eq "$(sg_hash "$SANDBOX/flatpak.override.system")" "$(sg_hash "$SANDBOX/override.orig")" "the system override is untouched"
}

test_a_user_override_with_other_settings_gets_the_by_hand_step_on_restore() {
    sl_flatpak_ready || return 1
    printf '[Context]\nfilesystems=home;\n' >"$SANDBOX/flatpak.override.user" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "configure"
    assert_contains "$(<"$SANDBOX/flatpak.override.user")" "org.freedesktop.Flatpak=talk" "the permission was added"
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore"
    assert_contains "$OUT" "by hand: remove the line org.freedesktop.Flatpak=talk" "the by-hand step, no reset"
    assert_contains "$(<"$SANDBOX/flatpak.override.user")" "filesystems=home;" "the user's own setting is kept"
}

test_a_symlinked_temp_directory_is_refused_before_the_sandbox_is_removed() {
    sl_flatpak_ready || return 1
    mkdir -p -- "$SANDBOX/elsewhere" "${SL_TMPDIR%/*}" && ln -sfn -- "$SANDBOX/elsewhere" "$SL_TMPDIR" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 1 "refused"
    assert_contains "$ERR" "$SL_TMPDIR is a symlink, not a directory or not yours" "says why"
    assert_not_contains "$(sg_log)" "override --user --talk-name" "the sandbox was never removed"
    sl_flatpak_untouched "symlinked temp directory"
    rm -f -- "$SL_TMPDIR"
}

test_a_wrapper_made_by_hand_is_never_replaced_or_removed() {
    sl_flatpak_ready || return 1
    sl_hand_wrapper || return 1
    cp -- "$SL_WRAPPER" "$SANDBOX/wrapper.orig" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 1 "refused"
    assert_contains "$ERR" "was not written by this tool" "says why"
    assert_eq "$(sg_hash "$SL_WRAPPER")" "$(sg_hash "$SANDBOX/wrapper.orig")" "the hand-made wrapper is kept"
    assert_no_file "$SANDBOX/flatpak.override.user" "nothing else changed"
    rm -f -- "$SL_WRAPPER" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "configure once the hand-made wrapper is gone"
    cp -- "$SANDBOX/wrapper.orig" "$SL_WRAPPER" || return 1
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore"
    assert_contains "$OUT" "was not written by this tool" "says the wrapper was left"
    assert_eq "$(sg_hash "$SL_WRAPPER")" "$(sg_hash "$SANDBOX/wrapper.orig")" "a wrapper replaced by hand survives the restore"
}

test_a_running_flatpak_smartgit_is_refused_and_a_stale_ps_entry_is_not() {
    sl_flatpak_ready || return 1
    sl_flatpak_running || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 1 "a live instance is refused"
    assert_contains "$ERR" "SmartGit is running" "says why"
    sl_flatpak_untouched "running"
    sl_flatpak_stale_only || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "an instance whose pid is gone does not count"
}

test_a_rerun_carries_the_earlier_record_forward() {
    sl_flatpak_configure || return 1
    assert_rc 0 "first run"
    cp -- "$SANDBOX/prefs.orig" "$SG_PREFS" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "second run after SmartGit went back to its bundled git"
    assert_eq "$(grep -E '^(override|wrapper|vmoption|tmpdir)=' "$SL_FLATPAK_RECORD")" "$(printf 'override=yes\nwrapper=yes\nvmoption=yes\ntmpdir=yes')" "earlier yes values carried"
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore"
    sl_flatpak_untouched "after two runs and a restore"
}

test_a_terminal_no_to_the_sandbox_removal_changes_nothing() {
    sl_flatpak_ready || return 1
    # ^ invariant --configure-smartgit is the yes to pointing SmartGit at git => the sandbox question is the only prompt and gets the n
    gsg_pty $'n\n' install --configure-smartgit
    assert_rc 0 "a decline is not a failure"
    assert_contains "$OUT" "Step 1 removes the SmartGit sandbox" "the second question was asked"
    assert_contains "$OUT" "the sandbox removal was declined" "the No is said"
    sl_flatpak_untouched "declined at the terminal"
}

test_a_failing_override_command_rolls_the_flatpak_unit_back() {
    sl_flatpak_ready || return 1
    : >"$SANDBOX/flatpak.override.fail" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 1 "the failed step fails the run"
    assert_contains "$ERR" "flatpak override --user --talk-name=org.freedesktop.Flatpak $SL_APP_ID failed" "says which step"
    assert_not_contains "$ERR" "so nothing was restored; nothing was changed" "never claims nothing changed after the override ran"
    assert_contains "$ERR" "no Flatpak change was left to undo" "the failed override wrote nothing, so nothing was undone"
    assert_not_contains "$ERR" "undid the Flatpak changes" "never claims an undo that did not happen"
    sl_flatpak_untouched "rolled back"
}

test_a_failure_after_real_flatpak_changes_lists_exactly_what_was_undone() {
    sl_flatpak_ready || return 1
    rm -rf -- "${SL_TMPDIR%/*}" && : >"${SL_TMPDIR%/*}" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 1 "the temp directory cannot be made"
    assert_contains "$ERR" "cannot create $SL_TMPDIR" "says which step failed"
    assert_contains "$ERR" "undid the Flatpak changes of this run (the --user override, the wrapper)" "names exactly what was undone"
    sl_flatpak_untouched "rolled back after real changes"
    rm -f -- "${SL_TMPDIR%/*}"
}

test_the_sandbox_flag_without_configure_smartgit_is_a_usage_error() {
    sl_flatpak_ready || return 1
    gsg install --allow-smartgit-sandbox-removal </dev/null
    assert_rc 2 "usage error"
    assert_contains "$ERR" "--allow-smartgit-sandbox-removal needs --configure-smartgit" "says why"
}

# ^ invariant sl_interrupt_then_restore PATTERN SKIP stops the Flatpak setup with TERM at the move (or flatpak override) matching PATTERN after SKIP
# ^ invariant such moves; restore-smartgit must leave the Flatpak as sl_flatpak_ready made it, with no temp file of ours behind
sl_interrupt_then_restore() {
    sl_flatpak_ready || return 1
    sg_interrupt_run "$1" "$2" TERM "$GSG_PROJECT/bin/git-secret-guard" install --configure-smartgit --allow-smartgit-sandbox-removal || return 1
    rm -f -- "$SANDBOX/mv.stall" "$SANDBOX/mv.stallskip" || return 1
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore after a stop at [$1]"
    sl_flatpak_untouched "stopped at [$1], then restored"
    assert_no_file "$SL_TMPDIR" "no temp directory"
    assert_eq "$(compgen -G "${SL_WRAPPER%/*}/.git.gsg.*" || true)" "" "no wrapper temp file"
    assert_eq "$(compgen -G "${SL_VMOPTS%/*}/.smartgit.vmoptions.gsg.*" || true)" "" "no vmoptions temp file"
}

test_a_stop_at_the_first_flatpak_record_write_is_undone_by_restore() { sl_interrupt_then_restore flatpak.record 0; }
test_a_stop_inside_the_override_command_is_undone_by_restore() { sl_interrupt_then_restore --talk-name 0; }
test_a_stop_at_the_wrapper_rename_is_undone_by_restore() { sl_interrupt_then_restore host-bin/git 0; }
test_a_stop_at_the_vmoptions_rename_is_undone_by_restore() { sl_interrupt_then_restore smartgit.vmoptions 0; }
test_a_stop_at_the_flatpak_preferences_edit_is_undone_by_restore() { sl_interrupt_then_restore preferences.yml 0; }
# ^ order each step writes the record once before it acts; override = write 0, wrapper = 1, temp directory = 2, vmoptions = 3
test_a_stop_in_the_flatpak_temp_directory_step_is_undone_by_restore() { sl_interrupt_then_restore flatpak.record 2; }

test_a_rerun_after_a_stop_completes_the_flatpak_setup_and_restore_undoes_it() {
    sl_flatpak_ready || return 1
    sg_interrupt_run host-bin/git 0 TERM "$GSG_PROJECT/bin/git-secret-guard" install --configure-smartgit --allow-smartgit-sandbox-removal || return 1
    rm -f -- "$SANDBOX/mv.stall" "$SANDBOX/mv.stallskip" || return 1
    gsg install --configure-smartgit --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "the rerun completes the setup"
    assert_contains "$(<"$SL_WRAPPER")" "$SL_WRAPPER_MARKER" "the wrapper is ours"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$SL_WRAPPER" "the Git Executable is the wrapper"
    assert_contains "$(<"$SL_VMOPTS")" "-Djava.io.tmpdir=$SL_TMPDIR" "the vmoptions line is there"
    assert_file "$SL_TMPDIR" "the temp directory exists"
    assert_contains "$(cat "$SANDBOX/flatpak.override.user")" "org.freedesktop.Flatpak=talk" "the --user override is there"
    gsg restore-smartgit </dev/null
    assert_rc 0 "restore after the completed rerun"
    sl_flatpak_untouched "rerun after a stop, then restored"
    assert_no_file "$SL_TMPDIR" "no temp directory"
}

test_a_left_over_older_major_is_an_info_line_in_status_and_never_a_problem() {
    sl_leftover_setup || return 1
    gsg install </dev/null
    assert_rc 0 "install"
    assert_not_contains "$OUT$ERR" "run: git-secret-guard install --configure-smartgit" "no hint to configure a directory nobody uses"
    gsg status
    assert_rc 0 "status: the leftover does not count"
    assert_contains "$OUT" "SmartGit settings: $SL_OLD (25.1): $(sl_leftover_tail 25.1 26.1)" "one info line names the leftover"
    assert_not_contains "$OUT" "MISMATCH" "no MISMATCH anywhere"
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): $SANDBOX/pathbin/git, git 2.56.0; commits are scanned" "the live directory is judged as before"
}

test_doctor_prints_a_left_over_older_major_as_info_and_records_no_problem() {
    local rec=""
    sl_leftover_setup || return 1
    gsg install </dev/null
    assert_rc 0 "install"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 0 "doctor: no PROBLEM"
    assert_contains "$OUT" "  info     SmartGit 25.1 ($SL_OLD): $(sl_leftover_tail 25.1 26.1)" "the info line"
    assert_not_contains "$OUT" "PROBLEM" "no PROBLEM"
    if [ -f "$LC_STATE/findings" ]; then rec="$(<"$LC_STATE/findings")"; fi
    assert_not_contains "$rec" "SmartGit" "nothing of it is recorded, so no commit reminder names it"
}

test_configure_smartgit_exits_0_and_edits_nothing_when_only_a_leftover_is_old() {
    sl_leftover_setup || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 0 "the live directory is fine, the leftover is not an error"
    assert_not_contains "$ERR" "was not recorded" "the leftover is not refused"
    assert_contains "$OUT" "nothing to change" "says there is nothing to change"
    assert_eq "$(sg_hash "$SL_OLD/preferences.yml")" "$SL_OLD_HASH" "the leftover is never edited"
    assert_no_file "$SG_BACKUPS" "no backup or manifest"
}

test_a_live_directory_of_an_unrecorded_major_gets_the_by_hand_step_in_status_doctor_and_the_hint() {
    local by_hand='by hand: in SmartGit open Preferences, Commands, choose "Other Git Executable"'
    sl_tarball_setup || return 1
    rm -rf -- "$SG_SETTINGS" || return 1
    sl_extra_major "$LC_HOME/.config/smartgit" 27.1 linux-tarball-26.1 "$SL_INSTALL" || return 1
    gsg install </dev/null
    assert_rc 0 "install only prints the hint"
    assert_contains "$OUT" "SmartGit: found $LC_HOME/.config/smartgit/27.1" "the hint names the directory"
    assert_contains "$OUT" "so its commits are not scanned; $by_hand" "the hint gives the by-hand step"
    assert_not_contains "$OUT$ERR" "run: git-secret-guard install --configure-smartgit" "never the command that refuses 27.1"
    gsg status
    assert_rc 1 "a live directory still counts"
    assert_contains "$OUT" "(27.1): bundled git, git 2.53.0; commits are NOT scanned MISMATCH: $by_hand" "status gives the by-hand step"
    assert_not_contains "$OUT" "run: git-secret-guard install --configure-smartgit" "status never names the command"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor: a PROBLEM"
    assert_contains "$OUT" "PROBLEM  SmartGit 27.1 ($LC_HOME/.config/smartgit/27.1): Git Executable is the bundled git 2.53.0, so its commits are not scanned; $by_hand" "doctor gives the by-hand step"
    assert_not_contains "$OUT" "run: git-secret-guard install --configure-smartgit" "doctor never names the command"
}

test_an_older_flatpak_directory_is_left_over_until_the_installed_flatpak_has_that_major() {
    local root old
    sl_flatpak_setup linux-flatpak-26.1-byhand || return 1
    root="$LC_HOME/.var/app/$SL_APP_ID/config/smartgit"
    old="$root/25.1"
    sl_hand_wrapper || return 1
    sl_extra_major "$root" 25.1 linux-flatpak-26.1 /app || return 1
    gsg install </dev/null
    assert_rc 0 "install"
    gsg status
    assert_rc 0 "Flatpak 26.1.057 installed: 25.1 is left over"
    assert_contains "$OUT" "SmartGit settings: $old (25.1): $(sl_leftover_tail 25.1 26.1)" "the info line"
    printf '25_1_100\n' >"$SANDBOX/flatpak.version" || return 1
    gsg status
    assert_rc 1 "the installed Flatpak is 25.1.100: its directory is live and on the old bundled git"
    assert_contains "$OUT" "SmartGit settings: $old (25.1): bundled git, git 2.53.0; commits are NOT scanned MISMATCH: by hand:" "the by-hand step"
    assert_not_contains "$OUT" "run: git-secret-guard install --configure-smartgit" "status never names the refused command"
    assert_not_contains "$OUT" "left over" "nothing is left over now"
}

# ^ invariant sl_still_live LABEL = 26.1 (on the old bundled git) still counts, status exits 1 with MISMATCH and no directory is reported as left over
sl_still_live() {
    gsg status
    assert_rc 1 "$1: status still counts 26.1"
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): bundled git, git 2.53.0; commits are NOT scanned MISMATCH" "$1: 26.1 is judged"
    assert_not_contains "$OUT" "left over" "$1: nothing is left over"
}

test_a_newer_directory_smartgit_never_set_up_does_not_demote_the_live_one() {
    local newer
    sl_tarball_setup || return 1
    newer="$LC_HOME/.config/smartgit/26.2"
    mkdir -p -- "$newer" || return 1
    gsg install </dev/null
    sl_still_live "an empty 26.2"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor"
    assert_contains "$OUT" "PROBLEM  SmartGit 26.1 ($SG_SETTINGS): Git Executable is the bundled git 2.53.0" "doctor still has the PROBLEM"
    sl_extra_major "$LC_HOME/.config/smartgit" 26.2 linux-tarball-26.1 "$SL_INSTALL" || return 1
    rm -f -- "$newer/startup" || return 1
    sl_still_live "26.2 with a preferences file and no startup file (its wizard is open)"
    rm -rf -- "$newer" || return 1
    mkdir -p -- "$SANDBOX/elsewhere" && : >"$SANDBOX/elsewhere/startup" && ln -s -- "$SANDBOX/elsewhere" "$newer" || return 1
    sl_still_live "26.2 a symbolic link"
}

test_a_flatpak_whose_ps_fails_gets_the_flatpak_advice_not_install_pgrep() {
    sl_flatpak_setup || return 1
    rm -f -- "$SG_SETTINGS/startup" || return 1
    : >"$SANDBOX/flatpak.ps.fail" || return 1
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "refused"
    assert_contains "$ERR" "it cannot be told whether SmartGit is running" "says it cannot tell"
    assert_contains "$ERR" "check that flatpak ps works" "the advice names the tool that failed"
    assert_not_contains "$ERR" "install pgrep" "pgrep is not what the Flatpak check uses"
}

test_the_advice_for_an_untellable_process_check_depends_on_the_kind() {
    local script kind expected
    script='for l in smartgit smartgit_report smartgit_offer; do source "$GSG_ROOT/lib/$l.sh" || exit 9; done; smartgit_untellable_advice "$1"'
    while IFS='|' read -r kind expected; do
        gu_run "$script" "$kind"
        assert_rc 0 "$kind: the helper runs"
        assert_eq "$OUT" "$expected" "$kind: the advice"
    done <<'EOF'
linux|install pgrep
macos|install pgrep
flatpak|check that flatpak ps works
windows|
EOF
}

test_a_newer_directory_with_unreadable_preferences_is_a_warning_and_the_older_one_is_left_over() {
    local newer
    sl_tarball_setup || return 1
    newer="$LC_HOME/.config/smartgit/26.2"
    sg_point_at_git "$SG_PREFS" "$SANDBOX/pathbin/git" || return 1
    sl_extra_major "$LC_HOME/.config/smartgit" 26.2 linux-tarball-26.1 "$SL_INSTALL" || return 1
    grep -v '^  executable: ' "$newer/preferences.yml" >"$newer/preferences.new" && mv -- "$newer/preferences.new" "$newer/preferences.yml" || return 1
    gsg install </dev/null
    gsg status
    assert_rc 0 "status: an unreadable newer directory is not a problem"
    assert_contains "$OUT" "SmartGit settings: $newer (26.2): preferences.yml cannot be read as SmartGit writes it" "26.2 gets the cannot tell line"
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): $(sl_leftover_tail 26.1 26.2)" "26.1 is left over"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 0 "doctor"
    assert_contains "$OUT" "WARNING  SmartGit 26.2 ($newer): preferences.yml cannot be read as SmartGit writes it" "doctor warns for 26.2"
    assert_contains "$OUT" "  info     SmartGit 26.1 ($SG_SETTINGS): $(sl_leftover_tail 26.1 26.2)" "and has an info line for 26.1"
}

test_the_minor_of_a_major_compares_numerically() {
    sl_leftover_setup || return 1
    sl_extra_major "$LC_HOME/.config/smartgit" 26.2 linux-tarball-26.1 "$SL_INSTALL" || return 1
    sl_extra_major "$LC_HOME/.config/smartgit" 26.10 linux-tarball-26.1 "$SL_INSTALL" || return 1
    gsg install </dev/null
    gsg status
    assert_contains "$OUT" "(26.2): $(sl_leftover_tail 26.2 26.10)" "26.2 is older than 26.10"
    assert_not_contains "$OUT" "26.10): left over" "26.10 is the live one"
}

test_a_major_with_an_absurd_number_is_skipped_without_a_shell_error() {
    sl_leftover_setup || return 1
    sl_extra_major "$LC_HOME/.config/smartgit" 99999999999999999999.1 linux-tarball-26.1 "$SL_INSTALL" || return 1
    gsg install </dev/null
    gsg status
    assert_not_contains "$ERR" "integer" "no shell arithmetic error"
    assert_not_contains "$OUT$ERR" "99999999999999999999" "the directory is not taken for a SmartGit major"
    assert_rc 0 "26.1 stays live next to the 25.1 leftover"
}

test_a_running_smartgit_with_no_startup_file_names_running_first_and_the_missing_setup() {
    sl_tarball_setup || return 1
    rm -f -- "$SG_SETTINGS/startup" || return 1
    sg_running || return 1
    sl_tarball_refused "SmartGit (or another Syntevo app) of this user is running"
    assert_contains "${ERR%%no startup file*}" "is running" "running comes first"
    assert_contains "$ERR" "no startup file" "the missing setup is named too"
    assert_contains "${ERR%%Repository, Exit*}" "finish the wizard" "the wizard is finished first, it is modal and Exit is unreachable before"
    assert_contains "$ERR" "Repository, Exit" "then SmartGit is exited"
}

test_a_running_check_that_cannot_tell_and_no_startup_file_keep_the_install_pgrep_advice() {
    sl_tarball_setup || return 1
    rm -f -- "$SG_SETTINGS/startup" || return 1
    mkdir -p -- "$SANDBOX/no-tools" || return 1
    set_env GSG_SMARTGIT_TOOL_DIR="$SANDBOX/no-tools"
    sl_tarball_refused "it cannot be told whether SmartGit is running"
    assert_contains "$ERR" "no startup file" "the missing setup is named too"
    assert_contains "$ERR" "install pgrep" "and the pgrep advice of the plain refusal is kept"
}

run_file_tests
