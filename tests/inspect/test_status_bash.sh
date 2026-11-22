#!/usr/bin/env bash
# ^ invariant the recorded bash is judged on every platform, the hook command starts the hook with it (#28, #31)
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

lc_which() {
    # shellcheck disable=SC2016
    env -i HOME="$SANDBOX/home" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P "$1"' _ "$1" </dev/null
}

# ^ hazard an install from before the recorded bash has no BASH_BIN and the bare hook path => the shebang chooses the bash, a stand-in can win
test_status_flags_an_install_that_records_no_bash() {
    fresh_install
    sed -i '/^BASH_BIN=/d' "$LC_DATA/settings" || return 1
    gitx config --global --replace-all hook.git-secret-guard.command "$(git_path "$LC_DATA")/hooks/secret-scan" || return 1
    gsg status
    assert_rc 1 "an old install is a problem until install runs again"
    assert_contains "$OUT" "bash: MISMATCH (bash is not configured in the settings file; the hook command is the bare hook path, so the bash the script's shebang finds first on PATH runs the hook" "its own reason"
    assert_contains "$OUT" "run: git-secret-guard install)" "says how to fix it"
}

test_status_flags_a_recorded_bash_that_is_not_bash() {
    fresh_install
    printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/not-bash" && chmod 755 "$SANDBOX/not-bash" || return 1
    sed -i "s#^BASH_BIN=.*#BASH_BIN=$SANDBOX/not-bash#" "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "a program that is not bash"
    assert_contains "$OUT" "bash: MISMATCH ($SANDBOX/not-bash does not report bash 4.4 or newer" "named, with the reason"
}

run_file_tests
