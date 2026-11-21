#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ coupled the betterleaks the harness (tests/support/lib.sh) picks; the fetch-test-tools cache first, ~/.local/bin next, GSG_TEST_BETTERLEAKS over both

# ^ invariant harness_betterleaks HOME CACHE_ROOT [NAME=VALUE...] prints the REAL_BETTERLEAKS a fresh load of lib.sh picks for this HOME and cache root
harness_betterleaks() {
    local home="$1" cache_root="$2"
    shift 2
    # shellcheck disable=SC2016
    env -i HOME="$home" PATH="$PATH" XDG_CACHE_HOME="$cache_root" "$@" bash -c 'source "$1/tests/support/lib.sh" >/dev/null 2>&1; printf %s "$REAL_BETTERLEAKS"' _ "$GSG_PROJECT" </dev/null
}

test_the_default_betterleaks_is_the_one_fetch_test_tools_downloads() {
    local home="$SANDBOX/bl-home" cache="$SANDBOX/bl-cache/git-secret-guard-test-tools" got
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "the lookup order is the one of the Linux branch of tests/support/lib.sh"; fi
    if [ "$TEST_OS" = Darwin ]; then skip_test "the ~/.local/bin fallback is the Linux branch of tests/support/lib.sh; macOS always uses the cache path"; fi
    rm -rf -- "$home" "$SANDBOX/bl-cache" && mkdir -p -- "$home/.local/bin" "$cache" || return 1
    printf '#!/bin/sh\n' >"$cache/betterleaks" && cp -- "$cache/betterleaks" "$home/.local/bin/betterleaks" && chmod 755 "$cache/betterleaks" "$home/.local/bin/betterleaks" || return 1
    got="$(harness_betterleaks "$home" "$SANDBOX/bl-cache")"
    assert_eq "$got" "$cache/betterleaks" "the cache wins over ~/.local/bin"
    rm -f -- "$cache/betterleaks" || return 1
    got="$(harness_betterleaks "$home" "$SANDBOX/bl-cache")"
    assert_eq "$got" "$home/.local/bin/betterleaks" "without a cache copy ~/.local/bin is used"
    got="$(harness_betterleaks "$home" "$SANDBOX/bl-cache" GSG_TEST_BETTERLEAKS=/explicit/betterleaks)"
    assert_eq "$got" "/explicit/betterleaks" "GSG_TEST_BETTERLEAKS beats both"
}

run_file_tests
