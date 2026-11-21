#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup.sh"
# shellcheck source=tests/support/product_call.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/product_call.sh"

# ^ coupled the files install writes, leaves alone or gives a mode; a refused install writes no config, a dangling link stays empty, a stricter umask holds

test_a_dangling_global_config_symlink_leaves_no_empty_file_at_its_target() {
    local link="$SANDBOX/linkcfg" target="$SANDBOX/real-config"
    # ^ why nativestrict, not plain ln -s; plain ln -s on Git for Windows copies or fails and this test needs a real symlink
    MSYS=winsymlinks:nativestrict ln -s -- real-config "$link" 2>/dev/null
    if [ ! -L "$link" ]; then skip_test "this host cannot make a symbolic link"; fi
    set_env GSG_GIT="$GIT" GIT_CONFIG_GLOBAL="$(git_path "$link")"
    pc_run 'install_check_config_writable'
    assert_rc 0 "the probe through a dangling link works"
    assert_no_file "$target" "the probe left no empty config behind the link"
    [ -L "$link" ] || fail "the link itself is untouched"
}

test_an_old_git_refusal_leaves_no_global_config_behind() {
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "Linux package manager flows"; fi
    gu_rpm_setup || return 1
    mkdir -p -- "$SANDBOX/fresh" || return 1
    set_env GIT_CONFIG_GLOBAL="$SANDBOX/fresh/gitconfig"
    gsg install </dev/null
    assert_rc 1 "old git, no terminal, explicit config path"
    assert_contains "$ERR" "nothing was changed" "the claim"
    assert_no_file "$SANDBOX/fresh/gitconfig" "is true: no config file appeared"
    gu_rpm_setup || return 1
    lc_real_lookup
    rm -f -- "$LC_HOME/.gitconfig" "$LC_HOME/.config/git/config"
    gsg install </dev/null
    assert_rc 1 "old git, no terminal, git's own lookup"
    assert_contains "$ERR" "nothing was changed" "the claim again"
    assert_no_file "$LC_HOME/.gitconfig" "no ~/.gitconfig appeared"
    assert_no_file "$LC_HOME/.config/git/config" "and no XDG config"
    gu_rpm_setup || return 1
    printf '[user]\n\tname = Keep Me\n' >"$SANDBOX/gitconfig" || return 1
    cp -- "$SANDBOX/gitconfig" "$SANDBOX/gitconfig.before" || return 1
    gsg install </dev/null
    assert_eq "$(<"$SANDBOX/gitconfig")" "$(<"$SANDBOX/gitconfig.before")" "an existing config is byte for byte the same"
}

test_install_keeps_a_stricter_umask_of_the_caller() {
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "NTFS has no unix modes"; fi
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    run_cap bash -c 'umask 077; exec "$@"' _ env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" install
    assert_rc 0 "install under umask 077"
    assert_eq "$(stat -c %a "$LC_DATA/settings")" 600 "the caller's stricter umask is kept for the settings file"
}

run_file_tests
