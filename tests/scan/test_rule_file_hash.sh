#!/usr/bin/env bash
# ^ security the shipped betterleaks rule file is user-writable; the hook hashes it against the SHA-256 install recorded in the settings file (#26)
# ^ why stand-ins, not the real scanners; the check runs before betterleaks starts, the tests/scan/test_bypass_formats_real.sh C03 rows pin the real effect
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

SCAN="" OUTD="" CALLS=""
RULE_REL=lib/scan/betterleaks-rule.toml
# ^ invariant the hook names the file the way scanners/betterleaks.sh builds its path
RULE_SHOWN='lib/scan/scanners/../betterleaks-rule.toml'
MUTED='[allowlist]
regexes = ['"'''"'.*'"'''"']'

# ^ hazard one sandbox serves every test of the file => each test restores the share's rule file first, an edit never carries over
prepare() {
    cp -- "$GSG_PROJECT/$RULE_REL" "$SHARE/$RULE_REL" || return 1
    SCAN="$SANDBOX/scan-$1"
    OUTD="$SANDBOX/out-$1"
    CALLS="$SANDBOX/calls-$1"
    make_scan_tree "$SCAN"
    mkdir -p -- "$OUTD"
    set_env STUB_LOG="$CALLS" STUB_MARKER="$(new_marker)"
}
errors() { cat -- "$OUTD/betterleaks.errors" 2>/dev/null; }
edit_rule_file() { printf '\n%s\n' "$MUTED" >>"$SHARE/$RULE_REL"; }
# ^ invariant a settings file from before the check has no such line at all
drop_recorded_hash() { sed -i '/^BETTERLEAKS_RULE_SHA256=/d' "$SHARE/settings"; }
assert_betterleaks_ran() { assert_file "$CALLS" "$1: betterleaks was started"; }
assert_rule_file_blocked() {
    assert_rc 0 "$1: the adapter reports through the errors file"
    assert_contains "$(errors)" "the shipped rule file $SHARE/$RULE_SHOWN" "$1: names the file"
    assert_contains "$(errors)" "nothing was scanned" "$1: says nothing was scanned"
    assert_contains "$(errors)" "reinstall git-secret-guard from a checkout or a release" "$1: says how to recover"
    assert_no_file "$CALLS" "$1: betterleaks was not started"
}

test_a_rule_file_that_matches_the_recorded_hash_is_scanned() {
    prepare same
    use_stubs
    run_adapter betterleaks "$SCAN" "$OUTD"
    assert_rc 0 adapter
    assert_empty "$(errors)" "no error"
    assert_betterleaks_ran same
}

test_an_edited_rule_file_blocks_and_betterleaks_never_starts() {
    prepare edited
    use_stubs
    edit_rule_file
    run_adapter betterleaks "$SCAN" "$OUTD"
    assert_rule_file_blocked edited
    assert_contains "$(errors)" "does not match the SHA-256 install recorded" "says why"
}

test_a_rule_file_of_another_content_with_the_same_size_blocks() {
    prepare swap
    use_stubs
    # ^ why a same-size change, not an appended one; a length check alone would pass it
    sed -i '1s/^./#/' "$SHARE/$RULE_REL" || return 1
    run_adapter betterleaks "$SCAN" "$OUTD"
    assert_rule_file_blocked swap
}

test_no_recorded_hash_keeps_scanning_as_an_install_from_before_the_check_does() {
    prepare nokey
    use_stubs
    drop_recorded_hash
    edit_rule_file
    run_adapter betterleaks "$SCAN" "$OUTD"
    assert_rc 0 adapter
    assert_empty "$(errors)" "no error: the hook cannot judge a file without a record"
    assert_betterleaks_ran nokey
}

test_an_empty_recorded_hash_counts_as_none() {
    prepare emptykey
    use_stubs "BETTERLEAKS_RULE_SHA256="
    run_adapter betterleaks "$SCAN" "$OUTD"
    assert_empty "$(errors)" "no error"
    assert_betterleaks_ran emptykey
}

test_a_recorded_value_that_is_not_a_lowercase_sha256_blocks() {
    local bad n=0
    for bad in notahash 0123 "$(printf '%064d' 7)x" "$(printf 'A%.0s' {1..64})"; do
        n=$((n + 1))
        prepare "bad$n"
        use_stubs "BETTERLEAKS_RULE_SHA256=$bad"
        run_adapter betterleaks "$SCAN" "$OUTD"
        assert_rule_file_blocked "bad$n"
        assert_contains "$(errors)" "not a SHA-256" "bad$n: says the record is unusable"
    done
}

# ^ why a function in the settings, not a broken common.sh; settings load later and override it => stands in for a verdict failing oddly (127, mixed share)
test_an_unexpected_verdict_code_fails_closed() {
    prepare oddrc
    use_stubs 'rule_file_hash_check() { return 127; }'
    run_adapter betterleaks "$SCAN" "$OUTD"
    assert_rc 0 "the adapter reports through the errors file"
    assert_contains "$(errors)" "nothing was scanned" "an unknown verdict blocks"
    assert_no_file "$CALLS" "betterleaks was not started"
}

test_an_inherited_hash_in_the_environment_never_fills_the_gap() {
    prepare inherit
    use_stubs
    drop_recorded_hash
    set_env BETTERLEAKS_RULE_SHA256="$(printf '%064d' 1)"
    run_adapter betterleaks "$SCAN" "$OUTD"
    assert_empty "$(errors)" "the wrong inherited value was unset, the settings hold none"
    assert_betterleaks_ran inherit
}

test_an_inherited_hash_never_replaces_the_one_in_the_settings() {
    prepare inheritgood
    use_stubs
    edit_rule_file
    set_env BETTERLEAKS_RULE_SHA256="$(sha256sum <"$SHARE/$RULE_REL" | cut -d' ' -f1)"
    run_adapter betterleaks "$SCAN" "$OUTD"
    assert_rule_file_blocked inheritgood
}

test_a_commit_with_an_edited_rule_file_is_blocked_by_the_hook() {
    prepare commit
    use_stubs
    edit_rule_file
    new_repo rulecommit || return 1
    stage_file a.txt one || return 1
    commit_cap "edited rule file"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "betterleaks: the shipped rule file $SHARE/$RULE_SHOWN" "the hook says which file"
    assert_contains "$ERR" "nothing was scanned" "and that nothing was scanned"
    assert_not_contains "$(cat -- "$CALLS" 2>/dev/null)" "betterleaks dir" "betterleaks never scanned"
}

run_file_tests
