#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

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
        for word in "install" "--replace-hooks-path" "--with-timer" "uninstall" "--remove-tools" "status" "doctor" "--roots" "--recheck" "version" "help"; do
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
doctor --recheck --roots x
doctor --recheck stray
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

# ^ why a named bound, not a bare 20; it only guards a hang, the code under test must finish long before
CLI_LINK_WALK_TIMEOUT_S=20

# ^ why the caller passes the PATH among the env assignments, not a fixed one; each case picks its own PATH
# ^ why the harness bash by absolute path, not the shebang; on macOS 12 the shebang finds bash 3.2 and the bootstrap refuses, the walk is the subject
cli_prints_version() {
    local label="$1" script="$2" want
    shift 2
    want="$(<"$GSG_PROJECT/VERSION")" || return 1
    run_cap "$TEST_TIMEOUT" "$CLI_LINK_WALK_TIMEOUT_S" env -i "${LC_ENV[@]}" "$@" "${TEST_BASH:-$BASH}" "$script" version
    assert_rc 0 "$label"
    assert_eq "$OUT" "git-secret-guard $want" "$label prints the version"
}

# ^ external macOS 12 has no realpath in /usr/bin or /bin (#157) and the CLI resolves itself before the bootstrap; install_link_cli starts it by link
test_the_cli_started_through_links_finds_its_share_with_a_PATH_that_has_no_realpath() {
    realpath_free_path_dir || return 1
    lc_begin || return 1
    mkdir -p -- "$SANDBOX/links/sub" || return 1
    ln -s -- "$GSG_PROJECT/bin/git-secret-guard" "$SANDBOX/links/sub/inner" || return 1
    ln -s -- "sub/inner" "$SANDBOX/links/outer" || return 1
    ln -s -- "links" "$SANDBOX/dirlink" || return 1
    cli_prints_version "the file itself" "$GSG_PROJECT/bin/git-secret-guard" PATH="$NO_REALPATH_DIR"
    cli_prints_version "a relative link to an absolute link" "$SANDBOX/links/outer" PATH="$NO_REALPATH_DIR"
    cli_prints_version "a directory link on the way" "$SANDBOX/dirlink/outer" PATH="$NO_REALPATH_DIR"
    cli_prints_version "an exported CDPATH" "$SANDBOX/links/outer" PATH="$NO_REALPATH_DIR" CDPATH="$SANDBOX/links"
}

# ^ external on macOS 12 the shebang picks /bin/bash 3.2; the walk must succeed there and the bootstrap, not the walk, refuses (#157 died before it)
# ^ why one test for both hosts, not a skip; elsewhere the shebang bash is new enough and the version prints
test_the_cli_started_by_its_shebang_through_a_link_without_realpath_reaches_the_bootstrap() {
    realpath_free_path_dir || return 1
    lc_begin || return 1
    ln -s -- "$GSG_PROJECT/bin/git-secret-guard" "$SANDBOX/shebang-link" || return 1
    run_cap "$TEST_TIMEOUT" "$CLI_LINK_WALK_TIMEOUT_S" env -i "${LC_ENV[@]}" PATH="$NO_REALPATH_DIR" "$SANDBOX/shebang-link" version
    if ! old_system_bash; then
        assert_rc 0 "the shebang route"
        assert_eq "$OUT" "git-secret-guard $(<"$GSG_PROJECT/VERSION")" "the shebang route prints the version"
        return 0
    fi
    assert_rc 1 "the shebang route under bash 3.2"
    assert_contains "$ERR" "needs bash 4.4 or newer" "the bootstrap spoke"
    assert_not_contains "$ERR" "cannot resolve the location of this script" "the walk did not fail"
}

# ^ invariant the walk settles only on a regular file => a target missing from the disk is refused, as realpath without -m did
test_the_cli_refuses_a_link_whose_target_is_not_a_file() {
    cli_refuses_with_readlink_stand_in "a target that does not exist" missingbin 'printf "%s\n" "/no-such-file-157"'
}

# ^ why a readlink stand-in first on PATH, not a real loop; the kernel refuses a real loop before bash reads the script
cli_refuses_with_readlink_stand_in() {
    lc_begin || return 1
    mkdir -p -- "$SANDBOX/$2" || return 1
    printf '#!/bin/sh\n%s\n' "$3" >"$SANDBOX/$2/readlink" || return 1
    chmod +x "$SANDBOX/$2/readlink" || return 1
    ln -s -- "$GSG_PROJECT/bin/git-secret-guard" "$SANDBOX/$2-cli-link" || return 1
    run_cap env -i "${LC_ENV[@]}" PATH="$SANDBOX/$2:$TEST_BASE_PATH" \
        "$TEST_TIMEOUT" "$CLI_LINK_WALK_TIMEOUT_S" "${TEST_BASH:-$BASH}" "$SANDBOX/$2-cli-link" version
    assert_rc 1 "$1"
    assert_contains "$ERR" "cannot resolve the location of this script" "$1 says what failed"
    assert_empty "$OUT" "$1 prints nothing on stdout"
}

# ^ invariant the hop bound ends the walk => a link without an end is refused, never followed for ever
# shellcheck disable=SC2016
test_the_cli_refuses_a_link_that_never_settles_instead_of_hanging() {
    cli_refuses_with_readlink_stand_in "a link that never settles" loopbin 'printf "%s\n" "$1"'
}

test_the_cli_refuses_a_link_that_readlink_cannot_read_instead_of_guessing() {
    cli_refuses_with_readlink_stand_in "a link readlink cannot read" failbin 'exit 1'
}

run_file_tests
