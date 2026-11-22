#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ coupled the CLI wording when ctrl-c arrives during startup; a copy of the tree sends the signal from its own library, runs on Git for Windows too

# ^ invariant startup_tree NAME TEXT copies the product into SANDBOX/NAME and appends TEXT (a %b string) to its state library, loaded by every command
startup_tree() {
    local tree="$SANDBOX/$1"
    if [ -z "$SANDBOX" ] || [[ $SANDBOX != /* ]]; then fail "SANDBOX is not an absolute path"; return 1; fi
    rm -rf -- "$tree" && mkdir -p -- "$tree" || return 1
    cp -R -- "$GSG_PROJECT/bin" "$GSG_PROJECT/lib" "$GSG_PROJECT/VERSION" "$tree/" || return 1
    printf '%b' "$2" >>"$tree/lib/core/state.sh" || return 1
}

test_ctrl_c_while_the_cli_starts_says_that_nothing_was_changed() {
    # ^ why a signal sent by the library itself, not a timed kill; it is the same SIGINT a terminal sends, at a fixed point of the startup
    startup_tree startup-tree '\nkill -INT $$\n' || return 1
    run_cap env --default-signal=INT env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SANDBOX/startup-tree/bin/git-secret-guard" status
    assert_rc 130 "ended by the signal"
    assert_contains "$ERR" "interrupted" "says so"
    assert_contains "$ERR" "nothing was changed" "and that nothing was changed"
}

test_ctrl_c_while_the_cli_starts_names_a_homebrew_install_this_run_already_made() {
    # ^ why BREW_INSTALLED set by the library, not a real brew; it is the value the bootstrap leaves after brew install bash
    startup_tree startup-tree-brew '\nBREW_INSTALLED=bash\nkill -INT $$\n' || return 1
    run_cap env --default-signal=INT env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$SANDBOX/startup-tree-brew/bin/git-secret-guard" status
    assert_rc 130 "ended by the signal"
    assert_contains "$ERR" "the only change made was the Homebrew install of bash" "the claim is not nothing was changed"
    assert_not_contains "$ERR" "nothing was changed" "and no false claim"
}

run_file_tests
