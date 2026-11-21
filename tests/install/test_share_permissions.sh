#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

# ^ why a copy of the checkout, not the checkout itself; the test makes every file and directory of it writable by group and others
group_writable_checkout() {
    local dest="$SANDBOX/checkout2"
    rm -rf -- "${SANDBOX:?}/checkout2" && mkdir -p -- "$dest" || return 1
    cp -a -- "$GSG_PROJECT/hooks" "$GSG_PROJECT/lib" "$GSG_PROJECT/bin" "$GSG_PROJECT/tools.lock" "$GSG_PROJECT/VERSION" "$dest/" || return 1
    chmod -R go+w -- "$dest" || return 1
}

test_a_checkout_writable_by_group_and_others_installs_a_share_dir_nobody_else_can_write() {
    local src_bad share_bad
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "NTFS has no unix modes"; fi
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    group_writable_checkout || return 1
    find "$SANDBOX/checkout2" ! -type l \( -perm -020 -o -perm -002 \) >"$SANDBOX/perm.src" 2>"$SANDBOX/perm.err"
    assert_eq "$?" 0 "find ran on the copy ($(<"$SANDBOX/perm.err"))"
    src_bad="$(wc -l <"$SANDBOX/perm.src")"
    [ "$src_bad" -gt 0 ] || fail "the test checkout is not group or world writable, the test would prove nothing"
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$SANDBOX/checkout2/bin/git-secret-guard" install
    assert_rc 0 "install from a checkout whose files and directories are writable by group and others"
    assert_file "$LC_DATA/hooks/secret-scan" "the share dir was installed"
    find "$LC_DATA" ! -type l \( -perm -020 -o -perm -002 \) >"$SANDBOX/perm.out" 2>"$SANDBOX/perm.err"
    assert_eq "$?" 0 "find ran on the share dir ($(<"$SANDBOX/perm.err"))"
    share_bad="$(LC_ALL=C sort "$SANDBOX/perm.out")"
    assert_empty "$share_bad" "no directory or file of the installed share dir has a group or world write bit"
    find "$LC_DATA" -type d ! -perm -u+w >"$SANDBOX/perm.out" 2>"$SANDBOX/perm.err"
    assert_eq "$?" 0 "find ran for the owner bits ($(<"$SANDBOX/perm.err"))"
    assert_empty "$(<"$SANDBOX/perm.out")" "and the owner can still write every directory"
}

run_file_tests
