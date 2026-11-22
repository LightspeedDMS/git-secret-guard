#!/usr/bin/env bash
# ^ invariant fresh_install (tests/support/lifecycle.sh) hands each test a copy of the file's one real install; a test's changes never reach the next
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

LEAK=leak-marker-from-test-2

has_text() { [ -e "$1" ] && case "$(<"$1")" in *"$2"*) return 0 ;; esac; return 1; }

# ^ why the three tests are numbered, not named alike; run_file_tests runs them in name order and each reads what the one before left in the sandbox
# ^ why test 1 only builds the template, not the leak check; the first call installs for real and only a later call restores a copy
test_fresh_install_1_the_first_call_installs_and_saves_a_copy() {
    fresh_install || return 1
    gsg status
    assert_rc 0 "status after the real install"
    [ -d "$SANDBOX/$LC_TEMPLATE_NAME" ] || fail "no template was saved"
    : >"$SANDBOX/test-1-ran" || return 1
}

test_fresh_install_2_a_restored_copy_may_be_changed_everywhere() {
    [ -e "$SANDBOX/test-1-ran" ] || { fail "test 1 did not run before this one"; return 1; }
    fresh_install || return 1
    printf '\n# %s\n' "$LEAK" >>"$LC_DATA/hooks/secret-scan" || return 1
    printf '\n# %s\n' "$LEAK" >>"$LC_STATE/state" || return 1
    gitx config --global leak.marker "$LEAK" || return 1
    printf 'x\n' >"$SANDBOX/pathbin/leaked-tool" || return 1
    printf 'x\n' >"$SANDBOX/systemctl.log" || return 1
    printf 'x\n' >"$SANDBOX/xdg/leaked-file" || return 1
    printf 'x\n' >"$SANDBOX/fixtures/leaked-file" || return 1
    printf 'x\n' >"$LC_HOME/leaked-file" || return 1
    rm -f -- "$LC_BIN/git-secret-guard" || return 1
    : >"$SANDBOX/test-2-ran" || return 1
}

test_fresh_install_3_the_next_test_sees_none_of_it() {
    [ -e "$SANDBOX/test-2-ran" ] || { fail "test 2 did not run before this one"; return 1; }
    fresh_install || return 1
    if has_text "$LC_DATA/hooks/secret-scan" "$LEAK"; then fail "the share dir kept an edit"; fi
    if has_text "$LC_STATE/state" "$LEAK"; then fail "the state file kept an edit"; fi
    assert_empty "$(gitx config --global --get-regexp '^leak\.' || true)" "the global config kept a key"
    assert_no_file "$SANDBOX/pathbin/leaked-tool" "pathbin kept a file"
    assert_no_file "$SANDBOX/systemctl.log" "a stand-in log survived"
    assert_no_file "$SANDBOX/xdg/leaked-file" "xdg kept a file"
    assert_no_file "$SANDBOX/fixtures/leaked-file" "fixtures kept a file"
    assert_no_file "$LC_HOME/leaked-file" "home kept a file"
    [ -e "$LC_BIN/git-secret-guard" ] || fail "the CLI link removed by test 2 is not back"
    gsg status
    assert_rc 0 "status on the restored install"
    assert_contains "$OUT" "global config: matches" "the restored global config matches the restored install"
}

test_the_outside_listing_sees_a_new_file_a_changed_file_and_a_removed_one() {
    local before after
    lc_begin || return 1
    before="$(lc_outside_listing)" || return 1
    assert_eq "$(lc_outside_listing)" "$before" "a listing of an untouched sandbox is stable"
    printf 'x\n' >"$SANDBOX/schtasks.log" || return 1
    after="$(lc_outside_listing)" || return 1
    [ "$after" != "$before" ] || fail "a new stand-in log is not seen"
    printf 'y\n' >>"$SANDBOX/schtasks.log" || return 1
    [ "$(lc_outside_listing)" != "$after" ] || fail "a changed stand-in log is not seen"
    rm -f -- "$SANDBOX/schtasks.log" "$SANDBOX/pathbin/systemctl" || return 1
    [ "$(lc_outside_listing)" != "$before" ] || fail "a removed stand-in is not seen"
}

test_the_outside_listing_leaves_out_the_template_items_and_the_runner_files() {
    local before
    lc_begin || return 1
    mkdir -p -- "$SANDBOX/fixtures" || return 1
    before="$(lc_outside_listing)" || return 1
    printf 'x\n' >"$LC_HOME/anything" || return 1
    printf 'x\n' >"$SANDBOX/xdg/anything" || return 1
    printf 'x\n' >>"$SANDBOX/gitconfig" || return 1
    printf 'x\n' >"$SANDBOX/fixtures/anything" || return 1
    printf 'x\n' >>"$SANDBOX/.testout" || return 1
    printf 'x\n' >>"$SANDBOX/.out" || return 1
    printf 'x\n' >>"$SANDBOX/.err" || return 1
    assert_eq "$(lc_outside_listing)" "$before" "the items the template holds and the runner's own files are not part of the listing"
}

run_file_tests
