#!/usr/bin/env bash
# shellcheck disable=SC2016
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lifecycle.sh"
# shellcheck source=tests/integrations/desktop/desktop_git.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/desktop_git.sh"

# ^ external the Desktop feature is Linux only; the install flows run the real scanners and Desktop's real bundled git where it exists
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="GitHub Desktop on Linux"; fi

test_a_plain_install_with_desktop_present_prints_a_note_and_changes_nothing() {
    dg_install_begin || return 1
    dg_need_old_git
    gsg install </dev/null
    assert_rc 0 "install"
    assert_contains "$OUT" "GitHub Desktop" "the note names Desktop"
    assert_contains "$OUT" "git-secret-guard install --link-desktop-git" "and the flag"
    assert_contains "$ERR" "it is the git GitHub Desktop bundles" "the warning that its commits are not scanned stays without a link"
    assert_no_file "$DG_HOOKS" "no hooks directory without the flag"
    assert_no_file "$DG_LAUNCHER_USER" "no launcher without the flag"
}

test_a_linking_run_does_not_warn_that_desktops_commits_are_unscanned() {
    local warn="it is the git GitHub Desktop bundles"
    dg_install_begin || return 1
    dg_need_old_git
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "install --link-desktop-git ($ERR)"
    assert_not_contains "$ERR" "$warn" "no warning that Desktop's commits are not scanned: this run scans them"
    assert_contains "$OUT" "wrote the hooks directory" "the link lines are there"
    assert_contains "$OUT" "checked through" "and the self-check line"
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "a rerun of a current link ($ERR)"
    assert_not_contains "$ERR" "$warn" "a current link draws no warning either"
}

test_a_failing_self_check_still_shows_the_unscanned_warning() {
    local warn="it is the git GitHub Desktop bundles"
    lc_begin && lc_make_fixtures && lc_use_fixtures && dg_fixture || return 1
    dg_need_old_git
    DG_HOOKS="$LC_DATA/desktop-hooks"
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "stand-in scanners cannot pass the check"
    assert_contains "$ERR" "GitHub Desktop was not linked" "the link was rolled back"
    assert_contains "${ERR#*"GitHub Desktop was not linked"}" "$warn" "so the warning that Desktop's commits are not scanned is shown after that line"
    assert_not_contains "${ERR%%"GitHub Desktop was not linked"*}" "$warn" "and not before it"
    assert_eq "$(printf '%s\n' "$ERR" | grep -c -F "$warn")" 1 "exactly once"
}

test_a_failure_between_the_report_and_the_link_still_shows_the_warning_once() {
    local warn="it is the git GitHub Desktop bundles"
    dg_install_begin || return 1
    dg_need_old_git
    mkdir -p -- "$SANDBOX/xdg/data" && chmod 555 "$SANDBOX/xdg/data" || return 1
    gsg install --link-desktop-git </dev/null
    chmod 755 "$SANDBOX/xdg/data"
    assert_rc 1 "install fails after the report: the share dir cannot be made"
    assert_not_contains "$OUT" "wrote the hooks directory" "the link step never ran"
    assert_eq "$(printf '%s\n' "$ERR" | grep -c -F "$warn")" 1 "the warning install held back is printed once, on the way out"
}

test_install_with_the_flag_links_desktop_and_a_desktop_commit_of_a_fake_token_is_blocked() {
    local key
    key="$(fake_aws_key)"
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "install --link-desktop-git ($ERR)"
    assert_file "$DG_HOOKS/pre-commit" "the wrapper"
    assert_file "$DG_LAUNCHER_USER" "the launcher"
    assert_contains "$OUT" "restart GitHub Desktop" "the output says Desktop must be restarted"
    assert_contains "$OUT" "not covered" "and that other ways of starting it are not covered"
    assert_contains "$OUT" "checked through" "and that the check ran with Desktop's own git"
    assert_contains "$(<"$DG_LAUNCHER_USER")" "core.hooksPath=$DG_HOOKS" "the launcher names the hooks directory"
    dg_repo linked || return 1
    printf 'k = "%s"\n' "$key" >a.txt || return 1
    dgit "$DG_HOOKS" add a.txt || return 1
    dgit "$DG_HOOKS" commit -q -m t
    assert_rc 1 "a commit through Desktop's git with the launcher's environment is blocked"
    no_leak "$key"
}

test_a_failing_check_removes_everything_this_run_wrote_and_says_so() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && dg_fixture || return 1
    DG_HOOKS="$LC_DATA/desktop-hooks"
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "stand-in scanners cannot pass the check"
    assert_contains "$ERR" "a commit of a fake token in a file failed, but not with the findings text of the hook" "the check names what failed"
    assert_contains "$ERR" "GitHub Desktop was not linked; 28 files of the link (written by this run or an earlier one) were removed again" "and that the run undid itself"
    assert_no_file "$DG_HOOKS" "no hooks directory is left"
    assert_no_file "$DG_LAUNCHER_USER" "no launcher is left"
}

test_a_rerun_changes_nothing_a_plain_install_keeps_the_link_and_a_missing_wrapper_is_restored() {
    local before
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "first run ($ERR)"
    before="$(dg_snapshot)"
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "second run ($ERR)"
    assert_eq "$(dg_snapshot)" "$before" "no file was rewritten"
    assert_contains "$OUT" "are current; nothing was changed" "the output says so"
    assert_not_contains "$OUT" "restart GitHub Desktop" "and nothing says Desktop must be restarted: nothing changed"
    gsg install </dev/null
    assert_rc 0 "a plain install ($ERR)"
    assert_eq "$(dg_snapshot)" "$before" "keeps the link as it was (the share dir was replaced and the directory carried over)"
    rm -f -- "$DG_HOOKS/post-merge" || return 1
    gsg install </dev/null
    assert_rc 0 "a plain install after a wrapper went missing ($ERR)"
    assert_file "$DG_HOOKS/post-merge" "the wrapper is back without the flag"
    assert_contains "$OUT" "restart GitHub Desktop" "and the output says Desktop must be restarted"
}

test_every_refusal_happens_before_any_change() {
    DG_NO_DESKTOP_GIT_OK=1 dg_install_begin || return 1
    rm -rf -- "$DG_ROOT/usr/lib/github-desktop" || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "no Desktop"
    assert_contains "$ERR" "GitHub Desktop was not found" "says so"
    assert_contains "$ERR" "nothing was changed" "and that nothing changed"
    dg_nothing_changed
    dg_fixture || return 1
    mkdir -p -- "${DG_LAUNCHER_USER%/*}" && printf 'mine\n' >"$DG_LAUNCHER_USER" || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "a launcher entry of the user's own"
    assert_contains "$ERR" "$DG_LAUNCHER_USER exists and git-secret-guard did not write it" "names it"
    assert_eq "$(<"$DG_LAUNCHER_USER")" mine "and keeps it"
    assert_contains "$ERR" "Move it away (or add the environment by hand) and run install --link-desktop-git again" "the launcher keeps its own advice"
    dg_nothing_changed
    rm -f -- "$DG_LAUNCHER_USER" || return 1
    mkdir -p -- "$DG_HOOKS" && printf 'mine\n' >"$DG_HOOKS/pre-push" || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "a foreign file in the hooks directory"
    assert_contains "$ERR" "$DG_HOOKS/pre-push exists and git-secret-guard did not write it" "names it"
    assert_contains "$ERR" "Move it out of the hooks directory" "with advice that fits a file in the hooks directory"
    assert_not_contains "$ERR" "add the environment by hand" "not the advice for a launcher file"
    assert_no_file "$LC_STATE/state" "no state file"
    rm -rf -- "$LC_DATA" || return 1
    as_macos
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "not Linux"
    assert_contains "$ERR" "is for GitHub Desktop on Linux" "says so"
    dg_nothing_changed
}

test_unlink_removes_only_our_files_and_a_repeat_is_harmless() {
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    gsg unlink-desktop-git
    assert_rc 0 "unlink"
    assert_contains "$OUT" "removed 29 files of the GitHub Desktop link" "27 wrappers, the shared file and the launcher"
    assert_no_file "$DG_HOOKS" "the directory is gone"
    assert_no_file "$DG_LAUNCHER_USER" "the launcher is gone"
    assert_file "$LC_DATA/hooks/secret-scan" "the installed hook is untouched"
    gsg unlink-desktop-git
    assert_rc 0 "a repeat"
    assert_contains "$OUT" "nothing to unlink" "says so"
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link again ($ERR)"
    dg_foreign_launcher_kept unlink-desktop-git
    assert_no_file "$DG_HOOKS" "the wrappers are gone"
}

test_uninstall_removes_the_link_and_keeps_a_launcher_that_is_not_ours() {
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$OUT" "removed the GitHub Desktop link (29 files" "says what it removed"
    assert_no_file "$DG_LAUNCHER_USER" "the launcher is gone"
    assert_no_file "$LC_DATA" "so is the share dir"
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link again ($ERR)"
    dg_foreign_launcher_kept uninstall
}

test_uninstall_stops_and_keeps_a_file_of_the_users_in_the_hooks_directory() {
    local before
    DG_NO_DESKTOP_GIT_OK=1 dg_install_begin || return 1
    gsg install </dev/null
    assert_rc 0 "plain install, no link ($ERR)"
    mkdir -p -- "$DG_HOOKS" && printf 'mine\n' >"$DG_HOOKS/pre-commit" || return 1
    before="$(gitx config --global --list)"
    gsg uninstall
    assert_rc 1 "uninstall stops: the file is inside the share dir"
    assert_eq "$(gitx config --global --list)" "$before" "the hook configuration and core.hooksPath are as they were"
    assert_contains "$before" "hook.git-secret-guard.event" "and that configuration is there to keep"
    assert_contains "$ERR" "$DG_HOOKS/pre-commit was not written by git-secret-guard; left in place" "names the file"
    assert_contains "$ERR" "move them away and run uninstall again" "says what to do"
    assert_not_contains "$OUT" "removed the share dir" "and does not claim the share dir went"
    assert_eq "$(<"$DG_HOOKS/pre-commit")" mine "the file survived"
    assert_file "$LC_STATE/state" "the state is kept for the rerun"
    rm -f -- "$DG_HOOKS/pre-commit" || return 1
    gsg uninstall
    assert_rc 0 "uninstall after the file was moved away ($ERR)"
    assert_no_file "$LC_DATA" "the share dir is gone"
}

test_uninstall_and_unlink_name_and_keep_a_file_that_is_no_hook_name() {
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    printf 'mine\n' >"$DG_HOOKS/notes.txt" || return 1
    gsg unlink-desktop-git
    assert_rc 0 "unlink"
    assert_contains "$ERR" "$DG_HOOKS/notes.txt was not written by git-secret-guard; left in place" "unlink names it"
    assert_eq "$(<"$DG_HOOKS/notes.txt")" mine "and keeps it"
    gsg uninstall
    assert_rc 1 "uninstall stops for it"
    assert_contains "$ERR" "$DG_HOOKS/notes.txt was not written by git-secret-guard; left in place" "uninstall names it"
    assert_eq "$(<"$DG_HOOKS/notes.txt")" mine "and keeps it"
    assert_not_contains "$OUT" "removed the share dir" "the share dir is not reported removed"
}

test_a_system_entry_with_a_spaced_exec_key_still_gets_our_variable() {
    local spelling
    dg_install_begin || return 1
    for spelling in '  Exec=github-desktop %U' 'Exec =github-desktop %U'; do
        printf '[Desktop Entry]\nName=GitHub Desktop\n%s\nType=Application\n' "$spelling" >"$DG_LAUNCHER_SYS" || return 1
        gsg install --link-desktop-git </dev/null
        assert_rc 0 "link with a system entry spelled [$spelling] ($ERR)"
        assert_contains "$(<"$DG_LAUNCHER_USER")" 'Exec=env "GIT_CONFIG_PARAMETERS=' "the user entry carries the variable"
        assert_contains "$(<"$DG_LAUNCHER_USER")" ' github-desktop %U' "and still starts Desktop"
        gsg status
        assert_rc 0 "status after [$spelling]"
        assert_contains "$OUT" "GitHub Desktop: linked" "judged active because it is"
    done
}

test_a_kept_file_name_is_printed_without_control_characters() {
    local name=$'x\e[31mA\ngit-secret-guard: FAKE'
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    : >"$DG_HOOKS/$name" || return 1
    gsg unlink-desktop-git
    assert_rc 0 "unlink"
    assert_not_contains "$ERR" $'\e' "no escape character reaches the terminal"
    assert_not_contains "$ERR" $'\ngit-secret-guard: FAKE' "a newline in the name cannot fake a line"
    assert_contains "$ERR" "x?[31mA?git-secret-guard: FAKE was not written by git-secret-guard; left in place" "the name is shown with ? for each control character"
}

test_a_name_starting_with_two_dots_and_a_long_list_are_named() {
    local i
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    : >"$DG_HOOKS/..dotdot" || return 1
    gsg unlink-desktop-git
    assert_contains "$ERR" "$DG_HOOKS/..dotdot was not written by git-secret-guard; left in place" "a name starting with two dots is named"
    for i in 1 2 3 4; do : >"$DG_HOOKS/extra$i" || return 1; done
    gsg unlink-desktop-git
    assert_contains "$ERR" "and 2 more files in $DG_HOOKS were not written by git-secret-guard; left in place" "five foreign names: three shown and a count"
}

test_a_half_written_link_is_completed_by_a_plain_install() {
    dg_install_begin || return 1
    gsg install </dev/null
    assert_rc 0 "install ($ERR)"
    dg_run 'paths_init && desktop_git_paths && desktop_git_hooks_write "$GSG_SHARE" "$DG_HOOKS"'
    assert_rc 0 "a run killed after the hooks directory (simulated): only the wrappers exist ($ERR)"
    assert_no_file "$DG_LAUNCHER_USER" "no launcher yet"
    gsg install </dev/null
    assert_rc 0 "a plain install completes it ($ERR)"
    assert_file "$DG_LAUNCHER_USER" "the launcher is there"
    assert_contains "$OUT" "checked through" "the check ran before the launcher was written"
    assert_contains "$OUT" "restart GitHub Desktop" "and Desktop must be restarted"
}

test_a_launcher_that_cannot_be_written_rolls_the_whole_run_back() {
    dg_install_begin || return 1
    mkdir -p -- "$SANDBOX/xdg/data" && printf 'x\n' >"$SANDBOX/xdg/data/applications" || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "a launcher directory that cannot be made"
    assert_contains "$ERR" "GitHub Desktop was not linked; 28 files of the link (written by this run or an earlier one) were removed again" "the run undid itself"
    assert_no_file "$DG_HOOKS" "no hooks directory is left"
}

test_a_failed_refresh_of_an_existing_link_counts_the_files_of_the_earlier_run() {
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "first run ($ERR)"
    rm -f -- "$DG_LAUNCHER_USER" && chmod 555 -- "${DG_LAUNCHER_USER%/*}" || return 1
    gsg install --link-desktop-git </dev/null
    chmod 755 -- "${DG_LAUNCHER_USER%/*}" || return 1
    assert_rc 1 "the refresh cannot write the launcher into a read-only directory ($ERR)"
    assert_contains "$ERR" "GitHub Desktop was not linked; 28 files of the link (written by this run or an earlier one) were removed again" "the count is the files removed, all written by the earlier run"
    assert_not_contains "$ERR" "files this run wrote" "the old wording claimed only this run's files"
    assert_no_file "$DG_HOOKS" "the earlier run's hooks directory is gone"
}

test_an_active_link_silences_the_old_git_warnings_of_install_and_doctor() {
    local warn="it is the git GitHub Desktop bundles"
    dg_install_begin || return 1
    [ "$DG_OLD" -eq 1 ] || skip_test "needs GitHub Desktop's own old git; a git of 2.54 or newer draws no warning"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg install </dev/null
    assert_contains "$ERR" "$warn" "unlinked, install warns that Desktop's git is old"
    gsg doctor --roots "$SANDBOX/roots"
    assert_contains "$OUT" "$warn" "and doctor does too"
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    gsg install </dev/null
    assert_rc 0 "install with an active link ($ERR)"
    assert_not_contains "$ERR" "$warn" "install no longer calls Desktop's commits unscanned"
    gsg doctor --roots "$SANDBOX/roots"
    assert_not_contains "$OUT" "$warn" "doctor shows no old-git warning for Desktop"
    assert_contains "$OUT" "ok       GitHub Desktop: linked" "only the link line"
}

test_a_path_that_is_not_utf_8_is_refused_before_any_change() {
    local bad="$SANDBOX/xdg/bad-"$'\xff'
    DG_NO_DESKTOP_GIT_OK=1 dg_install_begin || return 1
    set_env XDG_DATA_HOME="$bad"
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "a launcher path GLib cannot load"
    assert_contains "$ERR" "is not valid UTF-8" "says why"
    assert_contains "$ERR" "nothing was changed" "and that nothing changed"
    [ ! -e "$bad" ] || fail "the refusal left $bad behind"
    assert_no_file "$LC_STATE/state" "no state file"
}

test_a_missing_iconv_is_named_and_refuses_before_any_change() {
    DG_NO_DESKTOP_GIT_OK=1 dg_install_begin || return 1
    printf '#!/bin/sh\nexit 127\n' >"$SANDBOX/pathbin/iconv" && chmod 755 "$SANDBOX/pathbin/iconv" || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "no iconv to check the path with"
    assert_contains "$ERR" "iconv is not installed" "says what is missing, not that something failed"
    assert_contains "$ERR" "nothing was changed" "and that nothing changed"
    assert_no_file "$LC_STATE/state" "no state file"
}

test_a_symbolic_link_at_the_hooks_dir_path_is_refused_by_install_and_left_alone_by_unlink() {
    local target="$SANDBOX/target"
    DG_NO_DESKTOP_GIT_OK=1 dg_install_begin || return 1
    mkdir -p -- "$target" "$LC_DATA" || return 1
    printf '#!/usr/bin/env bash\n%s\n' "# git-secret-guard: written by install --link-desktop-git; undone by unlink-desktop-git" >"$target/gsg-desktop-chain" || return 1
    ln -s gsg-desktop-chain "$target/pre-commit" && ln -s "$target" "$DG_HOOKS" || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 1 "a hooks directory that is a symbolic link"
    assert_contains "$ERR" "$DG_HOOKS is a symbolic link or not a directory" "named"
    assert_no_file "$LC_STATE/state" "refused before any change"
    assert_eq "$(find "$target" -mindepth 1 | wc -l)" 2 "nothing was written through the link"
    gsg unlink-desktop-git
    assert_rc 0 "unlink with a symbolic link there"
    assert_contains "$ERR" "$DG_HOOKS is a symbolic link or not a directory; it and what it holds are left in place" "names it"
    assert_eq "$(find "$target" -mindepth 1 | wc -l)" 2 "and removed nothing below it"
    [ -L "$DG_HOOKS" ] || fail "the link itself is gone"
    gsg uninstall
    assert_rc 1 "uninstall stops rather than delete the link it said it left in place"
    assert_not_contains "$OUT" "removed the share dir" "and does not claim the share dir went"
    [ -L "$DG_HOOKS" ] || fail "uninstall removed the link"
    assert_eq "$(find "$target" -mindepth 1 | wc -l)" 2 "and nothing below it"
}

test_a_run_killed_during_the_check_leaves_wrappers_only_and_a_rerun_completes() {
    local pid i status
    local -r stall_poll_max=120 stall_poll_interval=0.5
    dg_install_begin || return 1
    gsg install </dev/null
    assert_rc 0 "install ($ERR)"
    : >"$SANDBOX/dg.stall" || return 1
    setsid env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install --link-desktop-git </dev/null >"$SANDBOX/kill.out" 2>&1 &
    pid=$!
    for i in $(seq 1 "$stall_poll_max"); do
        if [ -f "$SANDBOX/dg.stalled" ]; then break; fi
        sleep "$stall_poll_interval"
    done
    assert_file "$SANDBOX/dg.stalled" "the check reached its first commit ($i polls)"
    kill -TERM -- "-$pid" || return 1
    wait "$pid"
    status=$?
    assert_eq "$status" 143 "the run ended on the signal"
    assert_eq "$(grep -c -F 'it is the git GitHub Desktop bundles' "$SANDBOX/kill.out")" 1 "the unscanned warning is printed once on the way out: Desktop was not linked"
    rm -f -- "$SANDBOX/dg.stall" || return 1
    assert_file "$DG_HOOKS/pre-commit" "the wrappers were written before the check"
    assert_no_file "$DG_LAUNCHER_USER" "the launcher is only written after the check"
    gsg status
    assert_rc 1 "status after the killed run"
    assert_contains "$OUT" "GitHub Desktop: MISMATCH the launcher entry is missing" "names the missing part"
    dg_repair
    assert_file "$DG_LAUNCHER_USER" "a rerun wrote the launcher"
}

run_file_tests
