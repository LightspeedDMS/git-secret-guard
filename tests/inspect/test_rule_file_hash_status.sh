#!/usr/bin/env bash
# ^ invariant status and doctor judge the share's betterleaks rule file with rule_file_hash_check, the verdict the hook blocks on (#26)
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/doctor.sh"

RULE_REL=lib/scan/betterleaks-rule.toml
BLOCKS="the hook blocks every commit: nothing is scanned; reinstall from a checkout or a release: bin/git-secret-guard install"

edit_share_rule_file() { printf '\n[allowlist]\nregexes = ['"'''"'.*'"'''"']\n' >>"$LC_DATA/$RULE_REL"; }

test_status_and_doctor_say_ok_when_the_rule_file_matches_the_recorded_hash() {
    dr_begin || return 1
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "  ok       rule file: $LC_DATA/$RULE_REL matches the SHA-256 install recorded" "status ok line"
    doctor
    assert_rc 0 "doctor"
    assert_contains "$OUT" "  ok       rule file: $LC_DATA/$RULE_REL matches the SHA-256 install recorded" "doctor ok line"
}

test_status_flags_an_edited_rule_file_as_a_problem() {
    dr_begin || return 1
    edit_share_rule_file || return 1
    gsg status
    assert_rc 1 "an edited rule file makes the hook block every commit"
    assert_contains "$OUT" "  PROBLEM  rule file: MISMATCH ($LC_DATA/$RULE_REL does not match the SHA-256 install recorded; $BLOCKS)" "status says what and what to do"
}

test_doctor_flags_an_edited_rule_file_as_a_problem() {
    dr_begin || return 1
    edit_share_rule_file || return 1
    doctor
    assert_rc 1 "a problem"
    assert_contains "$OUT" "  PROBLEM  rule file: $LC_DATA/$RULE_REL does not match the SHA-256 install recorded; $BLOCKS" "doctor says what and what to do"
}

test_status_and_doctor_flag_a_recorded_value_that_is_not_a_sha256() {
    dr_begin || return 1
    sed -i 's/^BETTERLEAKS_RULE_SHA256=.*/BETTERLEAKS_RULE_SHA256=notahash/' "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "status"
    assert_contains "$OUT" "rule file: MISMATCH ($LC_DATA/$RULE_REL cannot be checked: the value recorded in the settings file is not a SHA-256; $BLOCKS)" "status"
    doctor
    assert_rc 1 "doctor"
    assert_contains "$OUT" "  PROBLEM  rule file: $LC_DATA/$RULE_REL cannot be checked: the value recorded in the settings file is not a SHA-256; $BLOCKS" "doctor"
}

# ^ invariant the hook libraries line (status) already reports a missing file; a second line for the same cause would only repeat it
test_an_unreadable_rule_file_gets_no_rule_file_line() {
    dr_begin || return 1
    rm -f -- "$LC_DATA/$RULE_REL" || return 1
    gsg status
    assert_not_contains "$OUT" "rule file:" "status prints no rule file line"
    assert_contains "$OUT" "hook libraries" "and the hook libraries line is where it shows"
    doctor
    assert_not_contains "$OUT" "rule file:" "doctor prints none either"
}

run_file_tests
