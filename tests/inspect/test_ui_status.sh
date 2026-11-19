#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ invariant GSG_LIBS = the libraries bin/git-secret-guard sources, in its order
GSG_LIBS="core/common core/state install/tools install/hookspath scan/exempt autoupdate/timer platform/launchd platform/wsl install/install autoupdate/install_timer install/install_cmd install/install_tools gitup/gitup gitup/gitup_source integrations/smartgit/smartgit integrations/smartgit/smartgit_report integrations/smartgit/smartgit_offer integrations/smartgit/smartgit_lfs integrations/smartgit/smartgit_apply integrations/smartgit/smartgit_flatpak integrations/desktop/desktop_git integrations/desktop/desktop_git_check integrations/desktop/desktop_git_report install/uninstall inspect/status inspect/doctor inspect/doctor_repos inspect/doctor_findings autoupdate/autoupdate platform/winupdate platform/schtasks autoupdate/autoupdate_report"

# ^ invariant us_run CODE = the libraries loaded as the CLI does, in plain mode, followed by CODE; CODE defines its input stand-ins after the load
us_run() {
    run_cap env -i PATH="$TEST_BASE_PATH" bash -c '
        GSG_ROOT="$1"
        for lib in platform/brew '"$GSG_LIBS"'; do source "$GSG_ROOT/lib/$lib.sh" || exit 1; done
        STATUS_PROBLEMS=0 STATUS_WARNINGS=0 STATUS_SECTION=""
        '"$1" _ "$GSG_PROJECT"
}

test_a_desktop_that_is_not_linked_is_a_warning_an_active_link_is_ok_and_scanning_by_config_is_info() {
    local state level
    for state in "unlinked WARNING" "active ok" "scans info" "mismatch PROBLEM"; do
        read -r state level <<<"$state"
        us_run 'desktop_git_linux_state() { DG_STATE='"$state"' DG_TEXT="text of '"$state"'"; return 0; }
            desktop_git_status_lines; echo "p=$STATUS_PROBLEMS w=$STATUS_WARNINGS"'
        assert_rc 0 "$state"
        assert_contains "$OUT" "$(printf '  %-8s GitHub Desktop: text of %s' "$level" "$state")" "$state is $level"
    done
    us_run 'desktop_git_linux_state() { DG_STATE=unlinked DG_TEXT=x; return 0; }; desktop_git_status_lines; echo "p=$STATUS_PROBLEMS w=$STATUS_WARNINGS"'
    assert_contains "$OUT" "p=0 w=1" "a warning is counted, no problem"
}

test_an_unexpected_exit_status_of_the_hook_listing_is_one_problem_line() {
    us_run 'status_hook_ask() { return 7; }; status_hook_listing; echo "p=$STATUS_PROBLEMS"'
    assert_contains "$OUT" "  PROBLEM  hook list: the check ended with exit 7" "named"
    assert_contains "$OUT" "p=1" "counted once, not 7 times"
    us_run 'status_hook_ask() { return 2; }; status_hook_listing; echo "p=$STATUS_PROBLEMS"'
    assert_not_contains "$OUT" "the check ended with exit" "a status status_hook_ask produces prints nothing more"
    assert_contains "$OUT" "p=2" "and is added as it is"
}

test_a_failing_hooks_path_read_still_prints_the_system_git_and_unfinished_copy_lines() {
    us_run 'status_hook_listing() { :; }; status_conditional_includes() { :; }; status_git_lists_scopes() { return 0; }
        status_hooks_path() { return 1; }; status_system_git() { echo SYSTEM-GIT-LINE; }; status_unfinished_copy() { echo UNFINISHED-LINE; }
        status_git_lines 0; echo "rc=$?"'
    assert_contains "$OUT" "SYSTEM-GIT-LINE" "system git line"
    assert_contains "$OUT" "UNFINISHED-LINE" "unfinished copy line"
    assert_contains "$OUT" "rc=1" "the failure still reaches status_run"
}

run_file_tests
