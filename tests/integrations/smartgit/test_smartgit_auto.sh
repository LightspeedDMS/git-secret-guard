#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2119,SC2120
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/gitup.sh"
# shellcheck source=tests/support/gitup_macos.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/gitup_macos.sh"
# shellcheck source=tests/support/smartgit.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/smartgit.sh"
# shellcheck source=tests/integrations/smartgit/smartgit_linux.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/smartgit_linux.sh"

# ^ external a plain install sets SmartGit up by itself, no flag and no question; --dont-configure-smartgit turns it off; Linux and fake-Mac flows run here
# ^ invariant stand-ins of tests/support/smartgit.sh (brew, flatpak, dnf, apt, pgrep); no test installs a package or touches a real SmartGit
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the SmartGit Linux and macOS flows"; fi
GU_PTY_BSD=1

# ^ invariant sa_ready = a tarball SmartGit on its old bundled git, the real scanners and a working git-lfs; nothing is run yet
sa_ready() {
    sl_tarball_setup || return 1
    sg_real_tools || return 1
    sg_lfs_present
}

test_a_plain_install_points_a_closed_smartgit_at_the_git_in_use_with_no_flag_and_no_terminal() {
    local target="$SANDBOX/pathbin/git"
    sa_ready || return 1
    gsg install </dev/null
    assert_rc 0 "plain install on a machine with a SmartGit on its old bundled git ($ERR)"
    assert_contains "$OUT" "SmartGit plan (nothing has been changed yet)" "the plan is printed"
    assert_not_contains "$OUT$ERR" "[y/N]" "no question is asked"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$target" "executable: is the git status reports"
    assert_eq "$(sg_git_value executable.absolute "$SG_PREFS")" "$target" "executable.absolute: too"
    assert_eq "$(sg_others "$SG_PREFS")" "$(sg_others "$SANDBOX/prefs.orig")" "every other line is byte for byte the same"
    assert_contains "$OUT" "checked through $target: git lfs works, a fake-token commit was blocked" "the verification passed"
    assert_file "$SG_BACKUPS/lfs.record" "the Git LFS settings were recorded"
    gsg status
    assert_rc 0 "status after the automatic setup"
    assert_not_contains "$OUT" "MISMATCH" "status shows no MISMATCH"
    assert_contains "$OUT" "SmartGit settings: $SG_SETTINGS (26.1): $target, git 2.56.0; commits are scanned" "and the commits are scanned"
}

# ^ invariant sa_unchanged LABEL = preferences.yml is the original and no backup or manifest was written
sa_unchanged() {
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "$1: preferences.yml is byte-identical"
    assert_no_file "$SG_BACKUPS" "$1: no backup or manifest"
}

# ^ invariant sa_refusal NAME TEXT = a plain install printed TEXT, kept preferences.yml byte for byte and exited 0
sa_refusal() {
    gsg install </dev/null
    assert_rc 0 "$1: a refusal is a notice, not a failed install"
    assert_contains "$ERR" "$2" "$1: says why"
    assert_contains "$ERR" "SmartGit was not changed" "$1: and that nothing changed"
    sa_unchanged "$1"
}

# ^ invariant sa_status_mismatch NAME = status still exits 1 and says the commits are NOT scanned MISMATCH
sa_status_mismatch() {
    gsg status
    assert_rc 1 "$1: status keeps its MISMATCH"
    assert_contains "$OUT" "commits are NOT scanned MISMATCH" "$1: status says so"
}

test_every_refusal_of_the_automatic_setup_is_a_printed_notice_and_install_exits_0() {
    local target_hash
    sa_ready || return 1
    sg_running || return 1
    sa_refusal "running" "SmartGit (or another Syntevo app) of this user is running"
    sa_status_mismatch "running"
    sa_ready || return 1
    rm -f -- "$SG_SETTINGS/startup" || return 1
    sa_refusal "wizard not finished" "SmartGit is not set up yet here (no startup file)"
    sa_status_mismatch "wizard not finished"
    sa_ready || return 1
    cp -- "$SG_PREFS" "$SANDBOX/prefs.target" && rm -f -- "$SG_PREFS" && ln -s "$SANDBOX/prefs.target" "$SG_PREFS" || return 1
    target_hash="$(sg_hash "$SANDBOX/prefs.target")"
    sa_refusal "symbolic link" "is a symbolic link"
    assert_contains "$ERR" "by hand: in SmartGit open Preferences, Commands" "symbolic link: prints the manual steps"
    assert_eq "$(sg_hash "$SANDBOX/prefs.target")" "$target_hash" "symbolic link: the file it points to is untouched"
    assert_eq "$(readlink -- "$SG_PREFS")" "$SANDBOX/prefs.target" "symbolic link: and the link is still there"
    sa_ready || return 1
    grep -v '^  executable: ' "$SG_PREFS" >"$SANDBOX/prefs.broken" && cp -- "$SANDBOX/prefs.broken" "$SG_PREFS" || return 1
    cp -- "$SG_PREFS" "$SANDBOX/prefs.orig" || return 1
    sa_refusal "not the recorded shape" "does not have the recorded shape"
}

test_an_unrecorded_major_is_a_notice_with_the_manual_steps_and_install_exits_0() {
    local h
    sa_ready || return 1
    rm -rf -- "$SG_SETTINGS" || return 1
    sl_extra_major "$LC_HOME/.config/smartgit" 27.1 linux-tarball-26.1 "$SL_INSTALL" || return 1
    h="$(sg_hash "$LC_HOME/.config/smartgit/27.1/preferences.yml")"
    gsg install </dev/null
    assert_rc 0 "SmartGit 27.1 was never recorded: a notice"
    assert_contains "$ERR" "was not recorded" "says why"
    assert_contains "$ERR" "Other Git Executable" "prints the manual step"
    assert_eq "$(sg_hash "$LC_HOME/.config/smartgit/27.1/preferences.yml")" "$h" "preferences.yml is byte-identical"
    assert_no_file "$SG_BACKUPS" "no backup or manifest"
}

test_a_target_git_that_is_not_plain_is_a_notice_and_install_exits_0() {
    sa_ready || return 1
    mkdir -p -- "$SANDBOX/odd dir" || return 1
    cp -- "$SANDBOX/pathbin/git" "$SANDBOX/odd dir/git" && chmod 755 "$SANDBOX/odd dir/git" || return 1
    set_env PATH="$SANDBOX/odd dir:$SANDBOX/pathbin:$SANDBOX/lfsmissing:$TEST_BASE_PATH"
    gsg install </dev/null
    assert_rc 0 "install with a git whose path SmartGit's YAML cannot hold"
    assert_contains "$ERR" "is not an absolute path made of" "says why"
    assert_contains "$ERR" "SmartGit was not changed" "and that nothing changed"
    sa_unchanged "a git at a path with a space"
}

test_dont_configure_smartgit_changes_nothing_prints_the_hint_and_asks_nothing_even_at_a_terminal() {
    sa_ready || return 1
    gsg install --dont-configure-smartgit </dev/null
    assert_rc 0 "install --dont-configure-smartgit"
    assert_contains "$OUT" "SmartGit: found $SG_SETTINGS" "the hint names the directory"
    assert_contains "$OUT" "so its commits are not scanned; run: git-secret-guard install" "and says what sets it up"
    assert_not_contains "$OUT" "SmartGit plan" "no plan"
    sa_unchanged "without a terminal"
    gsg_pty $'y\n' install --dont-configure-smartgit
    assert_rc 0 "at a terminal"
    assert_contains "$OUT" "SmartGit: found $SG_SETTINGS" "the hint is printed at a terminal too"
    assert_not_contains "$OUT" "[y/N]" "no question at a terminal"
    sa_unchanged "at a terminal"
}

test_a_flatpak_without_the_sandbox_consent_and_without_a_terminal_is_refused_with_the_manual_steps_and_install_exits_0() {
    sl_flatpak_ready || return 1
    gsg install </dev/null
    assert_rc 0 "a plain install: the refusal is a notice"
    assert_contains "$ERR" "step 1 removes the SmartGit sandbox and needs its own yes" "says why"
    assert_contains "$ERR" "4. in SmartGit choose Other Git Executable" "prints the manual steps"
    sl_flatpak_untouched "no consent"
    assert_not_contains "$OUT" "SmartGit plan" "no plan: nothing is going to run"
    gsg status
    assert_rc 1 "status keeps its MISMATCH"
}

test_the_sandbox_flag_alone_is_the_consent_for_the_automatic_flatpak_setup() {
    sl_flatpak_ready || return 1
    gsg install --allow-smartgit-sandbox-removal </dev/null
    assert_rc 0 "a plain install with the sandbox consent ($ERR)"
    assert_contains "$(<"$SL_WRAPPER")" "$SL_WRAPPER_MARKER" "the wrapper is written"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$SL_WRAPPER" "the Git Executable is the wrapper"
    assert_contains "$(cat "$SANDBOX/flatpak.override.user")" "org.freedesktop.Flatpak=talk" "the override is there"
}

# ^ invariant sa_lfs_refused ID COMMAND = a plain install on os-release ID names COMMAND for git-lfs, starts no package manager, changes nothing, exits 0
sa_lfs_refused() {
    sl_lfs_missing_setup "$1" || return 1
    printf '3.7.1\n' >"$SANDBOX/dnf.candidate" || return 1
    gsg install </dev/null
    assert_rc 0 "$1: a plain install that would need root for git-lfs ($ERR)"
    assert_contains "$ERR" "$2" "$1: the notice names the command to run"
    assert_contains "$ERR" "SmartGit was not changed" "$1: and that nothing changed"
    assert_not_contains "$(gu_log)" "install -y" "$1: no package manager was started"
    assert_not_contains "$(gu_log)" "sudo" "$1: nothing ran as root"
    sa_unchanged "$1"
}

test_git_lfs_that_needs_a_root_package_install_is_a_notice_with_the_command_and_nothing_runs() {
    sa_lfs_refused fedora "$SANDBOX/pathbin/dnf install -y git-lfs"
    sa_lfs_refused ubuntu "install -y git-lfs"
}

test_a_missing_git_lfs_without_a_terminal_on_a_mac_is_a_notice_naming_brew_and_brew_install_does_not_run() {
    local h
    sg_setup || return 1
    sg_real_tools || return 1
    h="$(sg_hash "$SG_PREFS")"
    gsg install </dev/null
    assert_rc 0 "a plain install without a terminal ($ERR)"
    assert_contains "$ERR" "brew install git-lfs" "the notice names the command to run as the user"
    assert_contains "$ERR" "SmartGit was not changed" "and that nothing changed"
    assert_not_contains "$(gm_calls)" "install git-lfs" "brew install never ran"
    assert_eq "$(sg_hash "$SG_PREFS")" "$h" "preferences.yml is byte-identical"
    assert_no_file "$SG_BACKUPS" "no backup or manifest"
}

test_a_missing_git_lfs_at_a_terminal_on_a_mac_is_installed_with_brew_after_the_plan_and_without_a_question() {
    sg_setup || return 1
    sg_real_tools || return 1
    gsg_pty '' install
    assert_rc 0 "a plain install at a terminal ($ERR)"
    assert_contains "$OUT" "SmartGit plan" "the plan is printed"
    assert_not_contains "$OUT" "[y/N]" "and nothing is asked"
    assert_contains "$(gm_calls)" "install git-lfs" "brew install git-lfs ran"
    assert_eq "$(sg_git_value executable "$SG_PREFS")" "$SANDBOX/pathbin/git" "the Git Executable points at the git in use"
}

test_a_failed_verification_is_rolled_back_with_a_notice_and_install_exits_0() {
    sg_setup || return 1
    sg_lfs_present || return 1
    cp -- "$SG_PREFS" "$SANDBOX/prefs.orig" || return 1
    gsg install </dev/null
    assert_rc 0 "the stand-in scanners cannot pass the check, the rollback worked ($ERR)"
    assert_contains "$ERR" "failed, but not with the findings text of the hook" "says what failed"
    assert_contains "$ERR" "SmartGit was restored from its backup" "and that it was restored"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "preferences.yml is the original again"
    gsg install --configure-smartgit </dev/null
    assert_rc 1 "the explicit flag keeps its status 1 for the same failure"
}

# ^ invariant a git wrapper spoils the backup at the commit; no real condition makes the restore fail on demand (as in the Desktop tests)
test_a_rollback_that_could_not_finish_makes_install_exit_1() {
    sa_ready || return 1
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.56.0"; exit 0; fi\ncase " $* " in *" commit "*) for f in "%s"/*.preferences.yml; do printf x >>"$f"; done; exit 1 ;; esac\nexec %s "$@"\n' "$SG_BACKUPS" "$GIT" >"$SANDBOX/pathbin/git" || return 1
    gsg install </dev/null
    assert_rc 1 "the backup no longer matches its manifest: something of ours is left behind"
    assert_contains "$ERR" "SmartGit was NOT fully restored" "says so"
    assert_contains "$ERR" "does not match the manifest" "and why"
}

# ^ invariant sa_silent = the last install printed no word of the SmartGit step; the bare word is no test, the override notice names GSG_SMARTGIT_*
sa_silent() {
    assert_not_contains "$OUT$ERR" "SmartGit plan" "no plan"
    assert_not_contains "$OUT$ERR" "SmartGit:" "no SmartGit line"
    assert_not_contains "$OUT$ERR" "SmartGit was" "no refusal or result"
}

test_nothing_to_do_prints_what_it_printed_before_with_no_smartgit_and_with_every_directory_scanned() {
    sa_ready || return 1
    rm -rf -- "$SG_SETTINGS" "$SL_INSTALL" || return 1
    gsg install </dev/null
    assert_rc 0 "no SmartGit"
    sa_silent
    sa_ready || return 1
    sg_point_at_git "$SG_PREFS" "$SANDBOX/pathbin/git" || return 1
    gsg install </dev/null
    assert_rc 0 "SmartGit already on a scanned git"
    sa_silent
    assert_no_file "$SG_BACKUPS" "no backup or manifest"
}

# ^ invariant a git-lfs stand-in locks the state directory at its install and fails; no real condition leaves the pending record unremovable on demand
# ^ external root ignores mode 555 on a directory, the record could be removed, the test skips
test_a_git_lfs_take_back_that_could_not_finish_makes_install_exit_1() {
    if [ "$(id -u)" -eq 0 ]; then skip_test "root removes a file from a directory with mode 555"; fi
    sa_ready || return 1
    gm_stub "$SANDBOX/pathbin/git-lfs" 'case "$1" in version) echo "git-lfs/3.8.0 (test stand-in)" ;; install) chmod 555 "'"$SG_BACKUPS"'"; exit 1 ;; *) exit 0 ;; esac' || return 1
    gsg install </dev/null
    chmod 755 "$SG_BACKUPS" || return 1
    assert_rc 1 "the pending record could not be taken back: something of ours is left behind"
    assert_contains "$ERR" "could not remove" "names the record"
    assert_contains "$ERR" "restore-smartgit" "and the command that finishes it"
    assert_eq "$(sg_hash "$SG_PREFS")" "$(sg_hash "$SANDBOX/prefs.orig")" "preferences.yml is untouched"
}

run_file_tests
