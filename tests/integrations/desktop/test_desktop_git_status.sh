#!/usr/bin/env bash
# shellcheck disable=SC2016
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../../support/lifecycle.sh"
# shellcheck source=tests/integrations/desktop/desktop_git.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/desktop_git.sh"

# ^ external the Desktop feature is Linux only; the status flows run the real scanners and Desktop's real bundled git where it exists
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="GitHub Desktop on Linux"; fi

test_status_shows_a_desktop_that_is_not_linked_as_a_warning() {
    dg_install_begin || return 1
    gsg install </dev/null
    assert_rc 0 "install ($ERR)"
    gsg status
    assert_rc 0 "status exits 0: linking is opt-in"
    [ "$DG_OLD" -eq 1 ] || skip_test "needs GitHub Desktop's own old git; a git of 2.54 or newer is reported as scanning by config"
    assert_contains "$OUT" "  WARNING  GitHub Desktop: git $DG_VER is not linked" "a WARNING line: it asks the user to act"
    assert_contains "$OUT" "run: git-secret-guard install --link-desktop-git" "and the command"
    assert_not_contains "$OUT" "MISMATCH" "it is no mismatch"
}

test_status_shows_an_active_link_as_current() {
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "  ok       GitHub Desktop: linked (git $DG_VER); the 27 wrappers, the shared file and the launcher entry are current" "active"
}

test_status_reports_missing_and_stale_parts_as_a_mismatch_with_the_command_to_run() {
    local fix=install\ --link-desktop-git
    dg_install_begin || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    rm -f -- "$DG_HOOKS/post-merge" || return 1
    dg_expect_mismatch "the hooks directory is missing or has changed files (post-merge)" "$fix"
    dg_repair
    rm -f -- "$DG_LAUNCHER_USER" || return 1
    dg_expect_mismatch "the launcher entry is missing" "$fix"
    dg_repair
    printf 'Comment[de]=Zusammenarbeit\n' >>"$DG_LAUNCHER_SYS" || return 1
    dg_expect_mismatch "the launcher entry differs from the system entry it is made from" "$fix"
    dg_repair
    rm -rf -- "$DG_ROOT/usr/lib/github-desktop" || return 1
    dg_expect_mismatch "GitHub Desktop was not found but its link is still there" unlink-desktop-git
}

test_on_macos_a_desktop_in_applications_gets_an_update_note_in_install_status_and_doctor() {
    DG_NO_DESKTOP_GIT_OK=1 dg_install_begin || return 1
    rm -rf -- "$DG_ROOT/usr/lib/github-desktop" || return 1
    as_macos
    gsg install </dev/null
    assert_rc 0 "install without Desktop ($ERR)"
    assert_not_contains "$OUT$ERR" "GitHub Desktop" "nothing is said when Desktop is not found"
    mkdir -p -- "$DG_ROOT/Applications/GitHub Desktop.app" || return 1
    gsg install </dev/null
    assert_rc 0 "install with Desktop ($ERR)"
    assert_contains "$OUT" "note: GitHub Desktop was found at $DG_ROOT/Applications/GitHub Desktop.app; update it to the latest release" "the install note"
    assert_contains "$OUT" "2.54 or newer" "and the reason"
    gsg status
    assert_contains "$OUT" "GitHub Desktop: found at $DG_ROOT/Applications/GitHub Desktop.app; update it to the latest release" "the status line"
    assert_not_contains "$OUT" "MISMATCH" "information only"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_contains "$OUT" "info     GitHub Desktop: found at $DG_ROOT/Applications/GitHub Desktop.app; update it to the latest release" "the doctor line"
    rm -rf -- "$DG_ROOT/Applications" || return 1
    mkdir -p -- "$LC_HOME/Applications/GitHub Desktop.app" || return 1
    gsg status
    assert_contains "$OUT" "GitHub Desktop: found at $LC_HOME/Applications/GitHub Desktop.app;" "the per-user Applications folder counts too"
}

test_on_windows_a_desktop_below_local_app_data_is_found_and_nothing_else_is() {
    lc_begin && dg_fixture || return 1
    lc_fake_uname MINGW64_NT-10.0-17763 x86_64 || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_other_path; printf "[%s]" "$REPLY"'
    assert_eq "$OUT" "[]" "LOCALAPPDATA is not set: nothing found"
    set_env LOCALAPPDATA="$SANDBOX/localapp"
    dg_run 'paths_init && desktop_git_paths && desktop_git_other_path; printf "[%s]" "$REPLY"'
    assert_eq "$OUT" "[]" "no GitHubDesktop directory: nothing found"
    mkdir -p -- "$SANDBOX/localapp/GitHubDesktop" || return 1
    dg_run 'paths_init && desktop_git_paths && desktop_git_other_note'
    assert_contains "$OUT" "note: GitHub Desktop was found at $SANDBOX/localapp/GitHubDesktop; update it to the latest release" "the note names the directory"
}

test_doctor_reports_the_desktop_link_as_info_ok_or_a_problem() {
    dg_install_begin || return 1
    [ "$DG_OLD" -eq 1 ] || skip_test "needs GitHub Desktop's own old git; a git of 2.54 or newer is reported as scanning by config"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg install </dev/null
    assert_rc 0 "install ($ERR)"
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 0 "doctor with Desktop not linked: the link is opt-in"
    assert_contains "$OUT" "info     GitHub Desktop: git $DG_VER is not linked" "information"
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 0 "doctor with an active link"
    assert_contains "$OUT" "ok       GitHub Desktop: linked (git $DG_VER)" "ok"
    printf 'Comment[de]=Zusammenarbeit\n' >>"$DG_LAUNCHER_SYS" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 0 "doctor after a Desktop update changed the system entry: the old entry still sets the variable"
    assert_contains "$OUT" "WARNING  GitHub Desktop: MISMATCH the launcher entry differs from the system entry it is made from; run: git-secret-guard install --link-desktop-git" "a warning, with the fix"
    gsg status
    assert_rc 1 "status still counts it as a mismatch"
    dg_repair
    rm -f -- "$DG_HOOKS/post-merge" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor with a stale link"
    assert_contains "$OUT" "PROBLEM  GitHub Desktop: MISMATCH the hooks directory is missing or has changed files (post-merge); run: git-secret-guard install --link-desktop-git" "a problem, with the fix"
}

test_doctor_calls_a_launcher_that_no_longer_sets_the_hooks_path_a_problem() {
    local line text=""
    dg_install_begin || return 1
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg install --link-desktop-git </dev/null
    assert_rc 0 "link ($ERR)"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line == Exec=* ]]; then line='Exec=github-desktop %U'; fi
        text+="$line"$'\n'
    done <"$DG_LAUNCHER_USER"
    printf '%s' "$text" >"$DG_LAUNCHER_USER" || return 1
    assert_contains "$(<"$DG_LAUNCHER_USER")" "written by install --link-desktop-git" "the marker is still there"
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor: Desktop would start unscanned"
    assert_contains "$OUT" "PROBLEM  GitHub Desktop: MISMATCH the launcher entry no longer sets core.hooksPath for Desktop; run: git-secret-guard install --link-desktop-git" "a problem, with the fix"
    gsg status
    assert_rc 1 "status agrees"
    dg_repair
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 0 "doctor after the repair"
    printf 'Exec=github-desktop --other\n' >>"$DG_LAUNCHER_USER" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor: a second Exec line without our setting"
    assert_contains "$OUT" "PROBLEM  GitHub Desktop: MISMATCH the launcher entry no longer sets core.hooksPath for Desktop" "every Exec line must carry it"
    dg_repair
    for line in '  Exec=github-desktop %U' 'Exec =github-desktop %U'; do
        printf '%s\n' "$line" >>"$DG_LAUNCHER_USER" || return 1
        gsg doctor --roots "$SANDBOX/roots"
        assert_rc 1 "doctor: GLib takes the last key, spelled [$line]"
        assert_contains "$OUT" "PROBLEM  GitHub Desktop: MISMATCH the launcher entry no longer sets core.hooksPath for Desktop" "[$line] is an Exec key"
        dg_repair
    done
    text="$(<"$DG_LAUNCHER_USER")"
    printf '%s\n' "${text//core.hooksPath=$DG_HOOKS/core.hooksPath=$SANDBOX/elsewhere}" >"$DG_LAUNCHER_USER" || return 1
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 1 "doctor: the setting names another directory"
    assert_contains "$OUT" "PROBLEM  GitHub Desktop: MISMATCH the launcher entry no longer sets core.hooksPath for Desktop" "the directory must be ours"
}

test_on_macos_the_desktop_update_advice_is_a_warning_in_status_and_an_icon_line_in_install() {
    local note
    DG_NO_DESKTOP_GIT_OK=1 dg_install_begin || return 1
    note="git-secret-guard: note: GitHub Desktop was found at $DG_ROOT/Applications/GitHub Desktop.app; update it to the latest release"
    rm -rf -- "$DG_ROOT/usr/lib/github-desktop" || return 1
    as_macos
    mkdir -p -- "$DG_ROOT/Applications/GitHub Desktop.app" || return 1
    gsg install </dev/null
    assert_contains "$OUT" $'\n'"$note" "the plain note"
    gsg status
    assert_contains "$OUT" "  WARNING  GitHub Desktop: found at $DG_ROOT/Applications/GitHub Desktop.app; update it to the latest release" "a warning line"
    assert_contains "$OUT" "1 warning" "counted, the singular"
    ui_force_terminal
    gsg install </dev/null
    assert_contains "$OUT" $'\n\e[33m▲\e[0m '"$note" "the note with the warning icon"
}

# ^ invariant a lifecycle test with no Desktop fixture sees no Desktop, whatever the host has in /usr/lib/github-desktop
# ^ why the empty-root run is the real guard, not the env check; it fails only on a host with Desktop installed, as a developer's machine may have
test_a_default_lifecycle_test_never_sees_the_hosts_github_desktop() {
    local tok found=0
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    for tok in "${LC_ENV[@]}"; do
        if [ "$tok" = "GSG_GITUP_ROOT=$SANDBOX/root" ]; then found=1; fi
    done
    assert_eq "$found" 1 "the default lifecycle env moves the system root into the sandbox"
    gsg install </dev/null
    assert_rc 0 "install ($ERR)"
    assert_not_contains "$OUT$ERR" "GitHub Desktop" "install names no Desktop"
    gsg status
    assert_rc 0 "status"
    assert_not_contains "$OUT" "GitHub Desktop" "status names no Desktop"
    assert_contains "$OUT" "summary: 0 problems, 0 warnings" "nothing is counted for Desktop"
    mkdir -p -- "$SANDBOX/root/usr/lib/github-desktop/resources/app/git/bin" || return 1
    printf '#!/bin/sh\necho "git version 2.45.3"\n' >"$SANDBOX/root/usr/lib/github-desktop/resources/app/git/bin/git" || return 1
    chmod 755 "$SANDBOX/root/usr/lib/github-desktop/resources/app/git/bin/git" || return 1
    gsg status
    assert_rc 0 "status with a Desktop at the host position of the sandbox root"
    assert_contains "$OUT" "  WARNING  GitHub Desktop: git 2.45.3 is not linked" "the default root is what status reads"
}

run_file_tests
