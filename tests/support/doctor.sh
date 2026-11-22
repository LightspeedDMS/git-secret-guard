#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
# ^ order sourced after tests/support/lib.sh and tests/support/lifecycle.sh => the doctor suites run on a sandbox machine installed from the fixtures
# ^ security every repository lives under $SANDBOX/roots and HOME is the sandbox home => doctor never reads the real ~/Dev or ~/.gitconfig

DR_ROOTS="" DR_REAL=""

# ^ external the fixtures install fake tools printing only their version; tests needing a real binary rewrite the settings
# ^ why fresh_install, not dr_install; default inputs mean one install per file and a restored copy per test (tests/support/lifecycle.sh)
# ^ hazard a test with other install inputs (fixture versions, LC_BINSHA, flags, a Mac flow) calls lc_begin and dr_install itself
dr_begin() {
    fresh_install && dr_roots
}

# ^ external a Mac answers Darwin from the real uname, other hosts from a fake one (as_macos); install runs on this flow
dr_begin_macos() {
    lc_begin && as_macos || return 1
    dr_install
}

# ^ why an empty roots dir made per call, not a shared one; every test starts from its own sandbox
dr_roots() {
    DR_ROOTS="$SANDBOX/roots"
    rm -rf -- "$DR_ROOTS" || return 1
    mkdir -p -- "$DR_ROOTS" || return 1
    DR_REAL="$(realpath -- "$DR_ROOTS")" || return 1
}

# ^ why lc_begin and the roots only, not dr_begin; a test calling lib functions or stopping before any machine check would not use an install
dr_begin_bare() {
    lc_begin || return 1
    dr_roots
}

dr_install() {
    lc_make_fixtures && lc_use_fixtures || return 1
    dr_roots || return 1
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

# ^ coupled lib/inspect/doctor_repos.sh:GSG_DOCTOR_FIND_DEPTH is 32; prints $1 plus $2 single-letter directories, 32 by default = past the limit whatever $1 is
deep_path() {
    local p="$1" i
    for ((i = 0; i < ${2:-32}; i++)); do p+=/d; done
    printf '%s' "$p"
}

# ^ external a socket on stdin makes the RHEL bash read ~/.bashrc even under env -i; HOME in the sandbox and stdin from /dev/null keep the lookup clean
# shellcheck disable=SC2016
dr_which() { env -i HOME="$SANDBOX/home" PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" bash -c 'type -P "$1"' _ "$1" </dev/null; }
