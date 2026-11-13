#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

# ^ why the real install, uninstall and state files, not a hand-set state; #97's review rejected a state set by hand (docs/install.md#maintainer-notes)
# ^ invariant LC_BINSHA=1 puts the stand-in binary's SHA-256 into the test lock as the fifth column => the same rows the product lock has (#101)

bin_sha() { sha256sum -- "$LC_BIN/$1$LC_EXE" | cut -d' ' -f1; }

# ^ invariant the file at the install path, if any, is untouched by the check; prints nothing
assert_scanners_recorded() {
    assert_eq "$(state_value tools_installed_by_us)" "trufflehog betterleaks" "$1: both scanners are install's own"
    assert_eq "$(state_value tools_placed)" "trufflehog:$(bin_sha trufflehog) betterleaks:$(bin_sha betterleaks)" "$1: with the hashes of the files on disk"
}

adopt_chain_until_second_install() {
    LC_BINSHA=1 lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "first install"
    gsg uninstall
    assert_rc 0 "uninstall without --remove-tools"
    assert_no_file "$LC_STATE/state" "the state is gone"
    [ -f "$LC_BIN/trufflehog$LC_EXE" ] && [ -f "$LC_BIN/betterleaks$LC_EXE" ] || fail "the scanners were kept"
    gsg install
    assert_rc 0 "second install"
}

test_scanners_kept_by_an_uninstall_are_adopted_and_removed_by_remove_tools() {
    lc_begin || return 1
    adopt_chain_until_second_install || return 1
    assert_scanners_recorded "after the reinstall"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_no_file "$LC_BIN/trufflehog$LC_EXE" "trufflehog is removed"
    assert_no_file "$LC_BIN/betterleaks$LC_EXE" "betterleaks is removed"
}

test_an_adopted_scanner_is_replaced_in_place_by_a_pin_bump_never_moved_aside() {
    lc_begin || return 1
    adopt_chain_until_second_install || return 1
    LC_BINSHA=1 lc_make_fixtures 3.99.3 1.9.1 || return 1
    gsg install
    assert_rc 0 "install with a bumped lock"
    assert_eq "$(find "$LC_BIN" -name '*.gsg-replaced-*' | wc -l)" 0 "nothing was moved aside as if it were the user's"
    assert_eq "$("$LC_BIN/trufflehog$LC_EXE" --version)" "trufflehog 3.99.3" "trufflehog is the new pin"
    assert_eq "$("$LC_BIN/betterleaks$LC_EXE" --version)" "betterleaks version 1.9.1" "betterleaks is the new pin"
    assert_eq "$(state_value tools_replaced)" "" "no replaced record"
    assert_scanners_recorded "after the bump"
}

test_a_scanner_kept_at_an_older_pin_is_still_moved_aside_as_the_users() {
    lc_begin || return 1
    LC_BINSHA=1 lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "first install"
    gsg uninstall
    assert_rc 0 "uninstall"
    LC_BINSHA=1 lc_make_fixtures 3.99.3 1.9.1 || return 1
    gsg install
    assert_rc 0 "install with a newer pin"
    assert_eq "$(find "$LC_BIN" -name 'trufflehog.gsg-replaced-*' | wc -l)" 1 "documented limit: the old file does not match the new lock, it is put aside"
    assert_eq "$(state_value tools_installed_by_us)" "" "and nothing is recorded as install's own"
}

test_a_different_file_at_the_install_path_is_never_adopted() {
    lc_begin && LC_BINSHA=1 lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_BIN" || return 1
    printf '#!/bin/sh\necho "trufflehog 3.99.2"\n# theirs\n' >"$LC_BIN/trufflehog$LC_EXE" && chmod 755 "$LC_BIN/trufflehog$LC_EXE" || return 1
    gsg install
    assert_rc 0 "install keeps a file that reports the pinned version"
    assert_contains "$(<"$LC_BIN/trufflehog$LC_EXE")" "# theirs" "the file is untouched"
    assert_eq "$(state_value tools_installed_by_us)" "betterleaks" "only the one install placed"
    assert_not_contains "$(state_value tools_placed)" "trufflehog:" "no hash recorded for the user's file"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    assert_file "$LC_BIN/trufflehog$LC_EXE" "the user's file stays"
}

test_a_link_at_the_install_path_is_never_adopted() {
    lc_begin && LC_BINSHA=1 lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$LC_BIN" "$SANDBOX/elsewhere" || return 1
    cp -- "$LC_FIX/src/trufflehog/trufflehog$LC_EXE" "$SANDBOX/elsewhere/" || return 1
    ln -s -- "$SANDBOX/elsewhere/trufflehog$LC_EXE" "$LC_BIN/trufflehog$LC_EXE" 2>/dev/null && [ -L "$LC_BIN/trufflehog$LC_EXE" ] || skip_test "this platform makes no symlinks"
    gsg install
    assert_rc 0 "install"
    assert_not_contains "$(state_value tools_placed)" "trufflehog:" "a link is not recorded"
    assert_eq "$(state_value tools_installed_by_us)" "betterleaks" "and not install's own"
    gsg uninstall --remove-tools
    assert_rc 0 "uninstall --remove-tools"
    [ -L "$LC_BIN/trufflehog$LC_EXE" ] || fail "the link stays"
}

test_a_lock_row_without_a_binary_hash_adopts_nothing() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "first install"
    gsg uninstall
    assert_rc 0 "uninstall"
    gsg install
    assert_rc 0 "second install"
    assert_eq "$(state_value tools_installed_by_us)" "" "the old behaviour: kept files are nobody's"
    assert_eq "$(state_value tools_placed)" "" "and unrecorded"
}

test_install_refuses_when_the_extracted_binary_is_not_the_one_the_lock_names() {
    local lock other
    lc_begin && LC_BINSHA=1 lc_make_fixtures && lc_use_fixtures || return 1
    lock="$LC_FIX/fixture.lock"
    other="$(printf 'not the binary\n' | sha256sum | cut -d' ' -f1)"
    sed -i "/^betterleaks /s/ [0-9a-f]\{64\}\$/ $other/" "$lock" || return 1
    gsg install
    assert_rc 1 "a binary that differs from the fifth column"
    assert_contains "$ERR" "the extracted betterleaks does not match the SHA-256 in the lock" "says what and why"
    assert_contains "$ERR" "install refused" "a staging refusal"
    assert_no_file "$LC_BIN/trufflehog$LC_EXE" "nothing was placed, not even the first tool"
    assert_no_file "$LC_BIN/betterleaks$LC_EXE" "nor the bad one"
    assert_no_file "$LC_STATE/state" "no state"
}

run_file_tests
