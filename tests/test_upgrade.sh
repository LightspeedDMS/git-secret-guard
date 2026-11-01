#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

ORIG_SHA="" ORIG_MODE=""

seed_user_gitleaks() {
    mkdir -p -- "$LC_BIN" || return 1
    printf '#!/bin/sh\necho "gitleaks version 8.18.4"\n# user build\n' >"$LC_BIN/gitleaks" || return 1
    chmod 750 "$LC_BIN/gitleaks" || return 1
    ORIG_SHA="$(sha256sum <"$LC_BIN/gitleaks")" || return 1
    ORIG_MODE="$(stat -c %a "$LC_BIN/gitleaks")" || return 1
}

# ^ external lc_make_fixtures rewrites fixture.lock => the next install sees the bumped pins, the earlier tarballs stay
bump_pins() { lc_make_fixtures "$1" "$2"; }

orig_is_back() {
    assert_eq "$(sha256sum <"$LC_BIN/gitleaks")" "$ORIG_SHA" "$1: the user's gitleaks is byte-identical"
    assert_eq "$(stat -c %a "$LC_BIN/gitleaks")" "$ORIG_MODE" "$1: and has its mode"
    assert_empty "$(find "$LC_BIN" -name '*.gsg-replaced-*')" "$1: no aside file is left"
}

test_a_pin_bump_replaces_install_own_tools_in_place_and_remove_tools_deletes_them() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "first install"
    bump_pins 3.99.3 8.30.2 || return 1
    gsg install
    assert_rc 0 "install from a checkout whose lock pins newer versions"
    assert_eq "$("$LC_BIN/trufflehog" --version)" "trufflehog 3.99.3" "trufflehog is the new pin"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.2" "gitleaks is the new pin"
    assert_empty "$(find "$LC_BIN" -name '*.gsg-replaced-*')" "install's own old binaries are not moved aside as 'originals'"
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog gitleaks" "both are still recorded as ours"
    assert_eq "$(state_value tools_replaced)" "" "and nothing is recorded as replaced"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_empty "$(find "$LC_BIN" -mindepth 1)" "nothing the user never had is left behind"
}

test_a_pin_bump_on_top_of_a_user_original_still_restores_the_users_file() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_gitleaks || return 1
    gsg install
    assert_rc 0 "first install over the user's gitleaks 8.18.4"
    bump_pins 3.99.3 8.30.2 || return 1
    gsg install
    assert_rc 0 "pin bump"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.2" "the new pin is in place"
    assert_eq "$(find "$LC_BIN" -name 'gitleaks.gsg-replaced-*' | wc -l)" 1 "only the user's file is aside, never install's own 8.30.1"
    gsg uninstall
    assert_rc 0 "uninstall"
    orig_is_back "after one pin bump"
}

test_chained_pin_bumps_keep_the_first_original_and_the_clean_removal() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_gitleaks || return 1
    gsg install
    bump_pins 3.99.3 8.30.2 || return 1
    gsg install
    bump_pins 3.99.4 8.30.3 || return 1
    gsg install
    assert_rc 0 "second pin bump"
    assert_eq "$("$LC_BIN/trufflehog" --version)" "trufflehog 3.99.4" "latest trufflehog"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    orig_is_back "after two pin bumps"
    assert_no_file "$LC_BIN/trufflehog" "trufflehog was ours alone, so it is gone"
}

seed_user_tools() {
    seed_user_gitleaks || return 1
    printf '#!/bin/sh\necho "trufflehog 3.0.0"\n# user build\n' >"$LC_BIN/trufflehog" || return 1
    chmod 700 "$LC_BIN/trufflehog" || return 1
    TRUFFLE_SHA="$(sha256sum <"$LC_BIN/trufflehog")" || return 1
}

# ^ security the stub fails only the staging copy of gitleaks and execs the real install otherwise
fail_install_of_gitleaks() {
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nfor a; do last=$a; done\ncase "$last" in *.gitleaks.gsg-new) echo "install: injected failure" >&2; exit 1 ;; esac\nexec /usr/bin/install "$@"\n' \
        >"$SANDBOX/pathbin/install" || return 1
    chmod 755 "$SANDBOX/pathbin/install"
}

test_a_state_that_cannot_be_written_leaves_the_users_tool_where_it_was() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_gitleaks || return 1
    rm -rf -- "$SANDBOX/xdg/state" && : >"$SANDBOX/xdg/state" || return 1
    gsg install
    assert_rc 1 "the state dir cannot be created"
    assert_eq "$(sha256sum <"$LC_BIN/gitleaks")" "$ORIG_SHA" "the user's gitleaks is still at its path, untouched"
    assert_empty "$(find "$LC_BIN" -name '*.gsg-replaced-*')" "nothing was moved aside"
    assert_not_contains "$OUT$ERR" "uninstall puts it back" "and no promise was printed"
    rm -f -- "$SANDBOX/xdg/state" && mkdir -p -- "$SANDBOX/xdg/state" || return 1
    gsg install
    assert_rc 0 "rerun once the cause is fixed"
    gsg uninstall
    assert_rc 0 "uninstall"
    orig_is_back "after the failed and the repeated install"
}

test_a_failure_placing_the_second_tool_still_lets_uninstall_restore_both_originals() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_tools && fail_install_of_gitleaks || return 1
    gsg install
    assert_rc 1 "gitleaks cannot be placed after trufflehog was"
    gsg uninstall
    assert_rc 0 "uninstall after the half-finished install"
    assert_eq "$(sha256sum <"$LC_BIN/trufflehog")" "$TRUFFLE_SHA" "the user's trufflehog is back"
    orig_is_back "second tool failed"
    assert_eq "$(stat -c %a "$LC_BIN/trufflehog")" 700 "with its mode"
    assert_contains "$ERR" "the planned move of $LC_BIN/gitleaks never happened; it is still in place" "the never-created aside is not reported as lost data"
    assert_not_contains "$ERR" "is missing" "and nothing is called missing"
}

test_a_state_dir_that_cannot_be_created_is_reported_with_the_reason_and_nothing_changed() {
    local state="$SANDBOX/xdg/state"
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_gitleaks || return 1
    rm -rf -- "$state" && : >"$state" || return 1
    gsg install
    assert_rc 1 "the state dir is under a regular file"
    assert_contains "$ERR" "git-secret-guard: cannot create the state dir $state/git-secret-guard (Not a directory); nothing was changed" "wrapped with the reason"
    assert_not_contains "$ERR" "mkdir:" "no bare coreutils line"
    rm -f -- "$state" && mkdir -p -- "$state" && chmod 500 "$state" || return 1
    gsg install
    assert_rc 1 "the state parent is read-only"
    assert_contains "$ERR" "git-secret-guard: cannot create the state dir $state/git-secret-guard (Permission denied); nothing was changed" "also for a permission problem"
    assert_not_contains "$ERR" "mkdir:" "no bare coreutils line either"
    chmod 700 "$state" || return 1
    assert_eq "$(sha256sum <"$LC_BIN/gitleaks")" "$ORIG_SHA" "the user's gitleaks never moved"
    assert_empty "$(find "$LC_BIN" -name '*.gsg-replaced-*')" "and nothing was set aside"
}

test_a_rerun_after_a_failure_placing_the_second_tool_ends_with_both_originals_restorable() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_tools && fail_install_of_gitleaks || return 1
    gsg install
    assert_rc 1 "gitleaks cannot be placed after trufflehog was"
    rm -f -- "$SANDBOX/pathbin/install"
    gsg install
    assert_rc 0 "rerun once the cause is fixed"
    assert_contains "$ERR" "is gone; its record is dropped" "the record of the aside that never happened is reconciled"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.1" "both pins are in place"
    assert_eq "$("$LC_BIN/trufflehog" --version)" "trufflehog 3.99.2" "after the rerun"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_eq "$(sha256sum <"$LC_BIN/trufflehog")" "$TRUFFLE_SHA" "the user's trufflehog is back"
    orig_is_back "rerun after failure"
}

test_a_missing_first_original_never_lets_a_later_record_be_restored() {
    local sha later="gitleaks.gsg-replaced-20200101T000000Z"
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_gitleaks || return 1
    gsg install
    assert_rc 0 "install over the user's gitleaks"
    cp -p -- "$LC_BIN"/gitleaks.gsg-replaced-2026* "$LC_BIN/$later" || return 1
    sha="$(sha256sum <"$LC_BIN/gitleaks" | cut -d' ' -f1)" || return 1
    sed -i "s#^tools_replaced=\\(.*\\)#tools_replaced=\\1 $later:$sha#" "$LC_STATE/state" || return 1
    rm -f -- "$LC_BIN"/gitleaks.gsg-replaced-2026* || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$ERR" "is missing" "the missing first original is reported"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.1" "the pinned tool stays, no later record is restored over it"
    assert_contains "$OUT" "another original of gitleaks is kept at $LC_BIN/$later" "the later file is only reported"
    assert_file "$LC_BIN/$later" "and it is still there"
}

test_a_state_dir_that_cannot_be_created_during_a_takeover_is_reported_the_same_way() {
    local state="$SANDBOX/xdg/state" hooks
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    hooks="$LC_HOME/old hooks"
    mkdir -p -- "$hooks" && printf '#!/bin/sh\n' >"$hooks/pre-commit" && gitx config --global core.hooksPath "$hooks" || return 1
    rm -rf -- "$state" && : >"$state" || return 1
    gsg install --replace-hooks-path
    assert_rc 1 "the backup needs the state dir, which cannot be created"
    assert_contains "$ERR" "git-secret-guard: cannot create the state dir $state/git-secret-guard (Not a directory); nothing was changed" "same wording as for the state file"
    assert_not_contains "$ERR" "mkdir:" "no bare coreutils line"
    assert_eq "$(gitx config --global --get core.hooksPath)" "$hooks" "core.hooksPath is untouched"
}

file_sha() { sha256sum -- "$1" | cut -d' ' -f1; }

test_a_failed_placement_of_the_second_tool_in_a_pin_bump_keeps_installs_own_file_installs_own() {
    local old_gl old_tr
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "first install"
    old_gl="$(file_sha "$LC_BIN/gitleaks")" old_tr="$(file_sha "$LC_BIN/trufflehog")" || return 1
    bump_pins 3.99.3 8.30.2 || return 1
    mkdir -- "$LC_BIN/.gitleaks.gsg-new" || return 1
    gsg install
    assert_rc 1 "gitleaks cannot be placed after trufflehog was"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.1" "install's own gitleaks is still at its path"
    assert_contains "$(state_value tools_placed)" "gitleaks:$old_gl" "and the state still records it as install's own"
    assert_eq "$(grep -c 'could not place' <<<"$ERR")" 1 "the real failure is reported once"
    assert_not_contains "$ERR" "Is a directory" "the cleanup of the staging path adds no second, misleading error"
    rm -rf -- "$LC_BIN/.gitleaks.gsg-new" || return 1
    gsg install
    assert_rc 0 "rerun once the cause is fixed"
    assert_empty "$(find "$LC_BIN" -name '*.gsg-replaced-*')" "install's own 8.30.1 was not moved aside as 'your original'"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.2" "the new pin is placed"
    assert_eq "$(state_value tools_replaced)" "" "nothing is recorded as replaced"
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog gitleaks" "both are still install's own"
    assert_eq "$(state_value tools_placed)" "trufflehog:$(file_sha "$LC_BIN/trufflehog") gitleaks:$(file_sha "$LC_BIN/gitleaks")" \
        "once placement is confirmed only the new hashes stay"
    assert_not_contains "$(state_value tools_placed)" "$old_gl" "the old gitleaks hash is gone"
    assert_not_contains "$(state_value tools_placed)" "$old_tr" "and so is the old trufflehog hash"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_empty "$(find "$LC_BIN" -mindepth 1)" "the bin dir holds no scanner the user never had"
}

test_a_failed_placement_of_the_first_tool_in_a_pin_bump_keeps_installs_own_file_installs_own() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "first install"
    bump_pins 3.99.3 8.30.2 || return 1
    mkdir -- "$LC_BIN/.trufflehog.gsg-new" || return 1
    gsg install
    assert_rc 1 "trufflehog cannot be placed, so nothing was"
    assert_eq "$("$LC_BIN/trufflehog" --version)" "trufflehog 3.99.2" "install's own trufflehog is still at its path"
    assert_eq "$("$LC_BIN/gitleaks" --version)" "gitleaks version 8.30.1" "and so is gitleaks"
    rm -rf -- "$LC_BIN/.trufflehog.gsg-new" || return 1
    gsg install
    assert_rc 0 "rerun once the cause is fixed"
    assert_empty "$(find "$LC_BIN" -name '*.gsg-replaced-*')" "no install-owned file was moved aside as the user's"
    assert_eq "$(state_value tools_replaced)" "" "nothing is recorded as replaced"
    assert_eq "$("$LC_BIN/trufflehog" --version)" "trufflehog 3.99.3" "the new trufflehog is placed"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_empty "$(find "$LC_BIN" -mindepth 1)" "nothing the user never had is left behind"
}

test_uninstall_after_a_failed_bump_accepts_any_recorded_hash_and_restores_the_users_original() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && seed_user_gitleaks || return 1
    gsg install
    assert_rc 0 "first install over the user's gitleaks 8.18.4"
    bump_pins 3.99.3 8.30.2 || return 1
    mkdir -- "$LC_BIN/.gitleaks.gsg-new" || return 1
    gsg install
    assert_rc 1 "gitleaks cannot be placed after trufflehog was"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    orig_is_back "after the failed bump"
    assert_no_file "$LC_BIN/trufflehog" "trufflehog was install's own at the new hash and is removed"
}

blocked_gitleaks_staging() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && mkdir -p -- "$LC_BIN/.gitleaks.gsg-new"
}

test_repeated_failed_placements_do_not_grow_tools_placed() {
    local i
    blocked_gitleaks_staging || return 1
    for i in 1 2 3; do
        gsg install
        assert_rc 1 "failed placement $i"
    done
    assert_eq "$(state_value tools_placed)" "trufflehog:$(file_sha "$LC_BIN/trufflehog") gitleaks:$(file_sha "$LC_FIX/src/gitleaks/gitleaks")" "each tool's hash appears once after three failures"
    rmdir -- "$LC_BIN/.gitleaks.gsg-new" || return 1
    gsg install
    assert_rc 0 "rerun once the cause is fixed"
    assert_eq "$(state_value tools_placed)" "trufflehog:$(file_sha "$LC_BIN/trufflehog") gitleaks:$(file_sha "$LC_BIN/gitleaks")" "and one hash per tool once placement is confirmed"
}

test_a_placement_blocked_by_a_directory_prints_one_clear_message_and_no_raw_install_line() {
    blocked_gitleaks_staging || return 1
    gsg install
    assert_rc 1 "a directory is in the way of the staging file"
    assert_eq "$(grep -c 'could not place' <<<"$ERR")" 1 "one could-not-place line"
    assert_eq "$(grep -c '^install:' <<<"$ERR" || true)" 0 "no raw line from coreutils install"
    assert_contains "$ERR" "git-secret-guard: could not place $LC_BIN/gitleaks (cannot write $LC_BIN/.gitleaks.gsg-new: cannot overwrite directory" "the reason is folded into the one message"
}

run_file_tests
