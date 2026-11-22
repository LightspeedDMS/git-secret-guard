#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/product_call.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/product_call.sh"

# ^ coupled the install warning about other gits (the one GitHub Desktop bundles, an old one later on PATH); a bare prelude, runs on Git for Windows too

test_the_git_bundled_with_github_desktop_is_named_and_said_to_skip_the_scan_as_measured() {
    pc_bundled_git 2.45.3 || return 1
    pc_old_git_dir || return 1
    pc_run_as_root "$PC_OLD_ON_PATH"'GSG_GIT="$(type -P git)"; GSG_GIT_USED="$(realpath -- "$GSG_GIT")"; install_report_other_gits' "$SANDBOX/oldgit"
    assert_rc 0 "a warning does not fail install"
    assert_contains "$ERR" "/usr/lib/github-desktop/resources/app/git/bin/git is git 2.45.3" "the bundled git and its version"
    assert_contains "$ERR" "GitHub Desktop" "says whose it is"
    assert_contains "$ERR" "commits made with it are not scanned (measured with 2.45.3)" "and that, as measured, its commits are not scanned"
    assert_not_contains "$ERR" "has not been tested" "the warning no longer says the question is open"
    assert_contains "$ERR" "oldgit/git is git 2.52.0; it ignores config-based hooks" "the second old git still gets the plain warning"
}

test_a_bundled_git_that_is_new_enough_is_not_warned_about() {
    pc_bundled_git 2.56.0 || return 1
    pc_old_git_dir || return 1
    pc_run_as_root "$PC_OLD_ON_PATH"'GSG_GIT="$(type -P git)"; GSG_GIT_USED="$(realpath -- "$GSG_GIT")"; install_report_other_gits' "$SANDBOX/oldgit"
    assert_rc 0 "no warning"
    assert_not_contains "$ERR" "github-desktop" "a git >= 2.54 reads config hooks"
}

run_file_tests
