#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"

test_version_prints_the_package_version() {
    lc_begin || return 1
    local want
    want="$(<"$GSG_PROJECT/VERSION")" || return 1
    [[ $want =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "VERSION is not x.y.z: [$want]"
    gsg version
    assert_rc 0 version
    assert_eq "$OUT" "git-secret-guard $want" "version output"
    gsg --version
    assert_rc 0 --version
    assert_eq "$OUT" "git-secret-guard $want" "--version output"
}

test_help_lists_every_command_and_flag() {
    lc_begin || return 1
    local arg word
    for arg in help --help -h; do
        gsg "$arg"
        assert_rc 0 "$arg"
        assert_empty "$ERR" "$arg prints nothing on stderr"
        for word in "install" "--replace-hooks-path" "--with-timer" "uninstall" "--remove-tools" "status" "doctor" "--roots" "version" "help"; do
            assert_contains "$OUT" "$word" "$arg mentions $word"
        done
    done
}

test_bad_usage_exits_2_and_changes_nothing() {
    lc_begin || return 1
    local args
    while IFS= read -r args; do
        # shellcheck disable=SC2086
        gsg $args
        assert_rc 2 "[$args]"
        assert_contains "$ERR" "git-secret-guard:" "[$args] says what is wrong"
        assert_empty "$OUT" "[$args] prints nothing on stdout"
    done <<'EOF'

doctor --bogus
doctor stray
doctor --roots
uninstall --with-timer
bogus
install --bogus
install --with-timer --bogus
install --remove-tools
uninstall --replace-hooks-path
uninstall extra
status extra
version extra
help extra
EOF
    assert_contains "$ERR" "usage:" "usage follows the error"
    assert_no_file "$LC_STATE" "no state was created"
    assert_no_file "$LC_DATA" "no share dir was created"
    assert_no_file "$LC_BIN" "no bin dir was created"
}

test_version_refuses_a_version_file_that_is_not_x_y_z() {
    lc_begin || return 1
    local copy="$SANDBOX/cli-copy"
    mkdir -p -- "$copy" && cp -a -- "$GSG_PROJECT/bin" "$GSG_PROJECT/lib" "$copy/" || return 1
    printf 'banana\n' >"$copy/VERSION" || return 1
    run_cap env -i "${LC_ENV[@]}" "$copy/bin/git-secret-guard" version
    assert_rc 1 "a bad VERSION"
    assert_contains "$ERR" "is not x.y.z: [banana]" "says why"
}

run_file_tests
