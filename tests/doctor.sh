#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# ^ order sourced after tests/lib.sh and tests/lifecycle.sh => the doctor suites run on a sandbox machine installed from the fixtures
# ^ security every repository lives under $SANDBOX/roots and HOME is the sandbox home => doctor never reads the real ~/Dev or ~/.gitconfig

DR_ROOTS="" DR_REAL=""

# ^ external the fixtures install fake tools printing only their version; tests needing a real binary rewrite the settings
dr_begin() {
    lc_begin || return 1
    dr_install
}

# ^ external a Mac answers Darwin from the real uname, other hosts from a fake one (as_macos); install runs on this flow
dr_begin_macos() {
    lc_begin && as_macos || return 1
    dr_install
}

dr_install() {
    lc_make_fixtures && lc_use_fixtures || return 1
    DR_ROOTS="$SANDBOX/roots"
    rm -rf -- "$DR_ROOTS" || return 1
    mkdir -p -- "$DR_ROOTS" || return 1
    DR_REAL="$(realpath -- "$DR_ROOTS")" || return 1
    gsg install
    assert_rc 0 "install for the doctor"
}

# ^ hazard a commit without --no-verify => the installed hook runs the fixture tools, they scan nothing and fail
dr_repo() {
    local dir="$DR_ROOTS/$1"
    mkdir -p -- "$dir" && gitx init -q "$dir" || return 1
    gitx -C "$dir" commit -q --allow-empty --no-verify -m init
}

doctor() { gsg doctor --roots "$DR_ROOTS"; }

# ^ external a socket on stdin makes the RHEL bash read ~/.bashrc even under env -i; HOME in the sandbox and stdin from /dev/null keep the lookup clean
# shellcheck disable=SC2016
dr_which() { env -i HOME="$SANDBOX/home" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P "$1"' _ "$1" </dev/null; }
