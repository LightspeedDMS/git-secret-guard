#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# ^ order sourced after tests/lib.sh, tests/lifecycle.sh and tests/gitup.sh; the macOS flow runs against the recording brew stand-in and its fake prefix
# ^ security no real brew exists on the PATH of these tests => no test can run a real brew install or brew upgrade

GM_PREFIX=""
GM_SHIM_SLEEP_SECONDS=8
GM_MAX_INSTALL_SECONDS=6

gm_calls() { grep -v '^--prefix' "$SANDBOX/brew.log" 2>/dev/null; }

# ^ invariant gm_stub FILE BODY writes an executable /bin/sh script (BODY is its text after the shebang), creating the directory
gm_stub() {
    mkdir -p -- "${1%/*}" || return 1
    printf '#!/bin/sh\n%s\n' "$2" >"$1" || return 1
    chmod 755 "$1"
}

# ^ invariant gm_git_script VERSION prints the path of a git wrapper reporting VERSION and running the real git otherwise
gm_git_script() {
    local f="$SANDBOX/brewsrc/git-$1"
    # shellcheck disable=SC2016
    gm_stub "$f" "if [ \"\$1\" = --version ]; then echo \"git version $1\"; exit 0; fi
exec $GIT \"\$@\"" || return 1
    printf '%s' "$f"
}

# ^ invariant gm_setup [OLD] leaves Homebrew with every formula except git; git OLD first on PATH (none when empty), the prefix bin dir ahead of it
gm_setup() {
    local src
    lc_begin && as_macos && lc_make_fixtures && lc_use_fixtures || return 1
    GM_PREFIX="$(cd -- "$SANDBOX" && pwd -P)/brewprefix"
    src="$(gm_git_script 2.56.0)" || return 1
    printf 'git|bin/git|%s\n' "$src" >>"$SANDBOX/brew.map" || return 1
    if [ -n "${1:-}" ]; then gu_old_git "$1" || return 1; fi
    set_env PATH="$GM_PREFIX/bin:$SANDBOX/pathbin:$TEST_BASE_PATH"
}

# ^ invariant gm_brew_git VERSION puts a Homebrew git of the given version into the fake prefix
gm_brew_git() {
    local src
    src="$(gm_git_script "$1")" || return 1
    ln -sfn -- "$src" "$GM_PREFIX/bin/git"
}

# ^ invariant id -u answers 0 for the CLI; on a Mac the fake gnubin comes first on its PATH, its id link is replaced too and must exist
gm_pretend_root() {
    # shellcheck disable=SC2016
    local body='if [ "$1" = -u ]; then echo 0; exit 0; fi
exec /usr/bin/id "$@"'
    local link="$GM_PREFIX/opt/coreutils/libexec/gnubin/id"
    gm_stub "$SANDBOX/pathbin/id" "$body" || return 1
    if [ "$TEST_OS" != Darwin ]; then return 0; fi
    if [ ! -L "$link" ]; then
        printf 'gm_pretend_root: %s is missing from the fake prefix\n' "$link" >&2
        return 1
    fi
    rm -f -- "$link" || return 1
    gm_stub "$link" "$body"
}

gm_nothing_installed() {
    assert_no_file "$LC_STATE" "$1: no state"
    assert_no_file "$LC_DATA" "$1: no share dir"
    assert_eq "$(gm_calls)" "" "$1: no brew call"
}
