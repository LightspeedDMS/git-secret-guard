#!/usr/bin/env bash
# ^ security install records the SHA-256 of the share's betterleaks rule file in the settings file; the hook, status and doctor judge the file by it (#26)
# ^ invariant the fixture tools are not real scanners => a blocked commit proves only the message the hook printed, never a finding
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/doctor.sh"

RULE_REL=lib/scan/betterleaks-rule.toml
KEY=BETTERLEAKS_RULE_SHA256

gsg_installed() { run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_DATA/bin/git-secret-guard" "$@"; }
recorded() { sed -n "s/^$KEY=//p" "$LC_DATA/settings"; }
file_sha() { local h; h="$(sha256sum <"$1")" || return 1; printf '%s' "${h%% *}"; }
edit_share_rule_file() { printf '\n[allowlist]\nregexes = ['"'''"'.*'"'''"']\n' >>"$LC_DATA/$RULE_REL"; }
try_commit() {
    new_repo "$1" || return 1
    stage_file a.txt one || return 1
    commit_cap "after $1"
}

test_install_records_the_sha256_of_the_rule_file_it_installed() {
    dr_begin || return 1
    assert_eq "$(recorded)" "$(file_sha "$GSG_PROJECT/$RULE_REL")" "the settings record the hash of the checkout's rule file"
    assert_eq "$(recorded)" "$(file_sha "$LC_DATA/$RULE_REL")" "which is the installed copy's hash"
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "  ok       rule file: $LC_DATA/$RULE_REL matches the SHA-256 install recorded" "status says so"
}

test_a_commit_is_blocked_when_the_share_rule_file_was_edited_after_install() {
    dr_begin || return 1
    edit_share_rule_file || return 1
    try_commit edited
    assert_rc 1 "blocked"
    assert_contains "$ERR" "betterleaks: the shipped rule file $LC_DATA/lib/scan/scanners/../betterleaks-rule.toml does not match the SHA-256 install recorded; nothing was scanned" "says what and why"
    assert_contains "$ERR" "reinstall git-secret-guard from a checkout or a release" "says how to recover"
}

test_an_install_run_from_the_installed_copy_refuses_an_edited_rule_file_and_changes_nothing() {
    dr_begin || return 1
    edit_share_rule_file || return 1
    cp -p -- "$LC_DATA/settings" "$SANDBOX/settings.before" && cp -p -- "$LC_DATA/$RULE_REL" "$SANDBOX/rule.before" && cp -p -- "$LC_STATE/state" "$SANDBOX/state.before" || return 1
    gsg_installed install
    assert_rc 1 "install refused"
    assert_contains "$ERR" "$LC_DATA/$RULE_REL" "names the file"
    assert_contains "$ERR" "install from a checkout or a release" "says what to do"
    cmp -s -- "$SANDBOX/settings.before" "$LC_DATA/settings" || fail "the settings changed"
    cmp -s -- "$SANDBOX/rule.before" "$LC_DATA/$RULE_REL" || fail "the rule file changed (blessed or replaced)"
    cmp -s -- "$SANDBOX/state.before" "$LC_STATE/state" || fail "the state file changed, so the refusal came after a lasting change"
}

test_an_install_run_from_the_installed_copy_refuses_a_rule_file_it_cannot_read() {
    dr_begin || return 1
    chmod 000 -- "$LC_DATA/$RULE_REL" || return 1
    if [ -r "$LC_DATA/$RULE_REL" ]; then
        chmod 644 -- "$LC_DATA/$RULE_REL"
        skip_test "this account reads a mode 000 file (root, or a platform without modes)"
    fi
    cp -p -- "$LC_DATA/settings" "$SANDBOX/settings.before" || return 1
    gsg_installed install
    chmod 644 -- "$LC_DATA/$RULE_REL" || return 1
    assert_rc 1 "install refused"
    assert_contains "$ERR" "cannot be hashed" "says why"
    cmp -s -- "$SANDBOX/settings.before" "$LC_DATA/settings" || fail "the settings changed"
}

test_an_install_run_from_a_checkout_whose_rule_file_cannot_be_read_refuses_before_any_change() {
    local co="$SANDBOX/checkout" item
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    mkdir -p -- "$co" || return 1
    for item in bin hooks lib tools.lock VERSION; do cp -r -- "$GSG_PROJECT/$item" "$co/" || return 1; done
    chmod 000 -- "$co/$RULE_REL" || return 1
    if [ -r "$co/$RULE_REL" ]; then skip_test "this account reads a mode 000 file (root, or a platform without modes)"; fi
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$co/bin/git-secret-guard" install
    chmod 644 -- "$co/$RULE_REL" || return 1
    assert_rc 1 "install refused"
    assert_contains "$ERR" "cannot hash the rule file $co/$RULE_REL" "names the file"
    assert_no_file "$LC_DATA" "nothing was installed"
}

test_an_install_run_from_a_checkout_replaces_an_edited_rule_file_and_records_the_shipped_hash() {
    dr_begin || return 1
    edit_share_rule_file || return 1
    gsg install
    assert_rc 0 "the install from the checkout"
    assert_eq "$(file_sha "$LC_DATA/$RULE_REL")" "$(file_sha "$GSG_PROJECT/$RULE_REL")" "the shipped file is back"
    assert_eq "$(recorded)" "$(file_sha "$GSG_PROJECT/$RULE_REL")" "and recorded"
    try_commit recovered
    assert_not_contains "$ERR" "the shipped rule file" "the hook no longer complains"
}

test_an_install_run_from_the_unedited_installed_copy_keeps_the_recorded_hash() {
    dr_begin || return 1
    local before
    before="$(recorded)"
    gsg_installed install
    assert_rc 0 "install from the installed copy"
    assert_eq "$(recorded)" "$before" "the same hash"
    assert_eq "$(file_sha "$LC_DATA/$RULE_REL")" "$before" "of the same file"
}

# ^ why an old install is built by deleting the line, not by installing an old release; the missing line is the whole difference between the two settings files
test_an_install_from_before_the_check_keeps_scanning_is_reported_and_is_recorded_by_the_next_install() {
    dr_begin || return 1
    sed -i "/^$KEY=/d" "$LC_DATA/settings" || return 1
    try_commit upgrade
    assert_not_contains "$ERR" "the shipped rule file" "the hook keeps scanning, it cannot judge a file without a record"
    assert_contains "$ERR" "git-secret-guard:" "and it ran"
    gsg status
    assert_rc 1 "status flags it"
    assert_contains "$OUT" "rule file: MISMATCH (no SHA-256 of $LC_DATA/$RULE_REL is recorded in the settings file, an install from before this check, so an edit of it is not noticed; run: git-secret-guard install)" "status says what to do"
    doctor
    assert_rc 1 "doctor flags it"
    assert_contains "$OUT" "  PROBLEM  rule file: no SHA-256 of $LC_DATA/$RULE_REL is recorded in the settings file, an install from before this check, so an edit of it is not noticed; run git-secret-guard install" "doctor says what to do"
    gsg install
    assert_rc 0 "the next plain install"
    assert_eq "$(recorded)" "$(file_sha "$GSG_PROJECT/$RULE_REL")" "records the hash"
    gsg status
    assert_rc 0 "status is clean"
    assert_contains "$OUT" "  ok       rule file: " "on that line"
}

# ^ security the first record after an upgrade trusts the share as it is (documented, docs/scan.md); from the installed copy it hashes the file on disk
test_an_install_from_the_installed_copy_of_an_old_install_records_the_file_on_disk() {
    dr_begin || return 1
    sed -i "/^$KEY=/d" "$LC_DATA/settings" || return 1
    gsg_installed install
    assert_rc 0 "install from the installed copy of an old install"
    assert_eq "$(recorded)" "$(file_sha "$LC_DATA/$RULE_REL")" "the hash of the file on disk"
}

run_file_tests
