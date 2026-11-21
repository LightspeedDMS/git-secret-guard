#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

# ^ invariant puts a uname on the sandbox PATH; it appends its first argument to $SANDBOX/uname.log and runs the host's own uname
# ^ why a PATH stand-in, not a function; the CLI and the hook are separate processes, and each uname they start must show in one log
uc_counter() {
    local real
    real="$(type -P uname)" || return 1
    rm -f -- "${SANDBOX:?}/uname.log"
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nprintf "%%s\\n" "$1" >>"%s/uname.log"\nexec "%s" "$@"\n' "$SANDBOX" "$real" >"$SANDBOX/pathbin/uname" || return 1
    chmod 755 "$SANDBOX/pathbin/uname"
}

# ^ invariant prints how many times uname ran with the argument $1; 0 when it never ran
uc_count() {
    if [ ! -f "$SANDBOX/uname.log" ]; then printf '0\n'; return 0; fi
    awk -v want="$1" '$0 == want { n++ } END { print n + 0 }' "$SANDBOX/uname.log"
}

# ^ why PATH put in EXTRA_ENV, not LC_ENV; gitx runs the commit with GSG_ENV, whose PATH has no sandbox stand-ins
uc_commit() {
    new_repo "$1" || return 1
    stage_file a.txt one two || return 1
    set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH"
    commit_cap "uname count"
}

# ^ invariant one install process asks uname -s once and uname -m once, for any number of platform checks in its libraries
test_install_runs_uname_s_once_and_uname_m_once() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && uc_counter || return 1
    gsg install
    assert_rc 0 "install"
    assert_eq "$(uc_count -s)" 1 "uname -s runs once for the whole install"
    assert_eq "$(uc_count -m)" 1 "uname -m runs once for the whole install"
}

# ^ invariant a commit runs four hook processes (supervisor, worker, one runner per scanner); each asks uname -s once and none asks uname -m
# ^ why 4, not 2; the two runners of lib/scan/run-scanner.sh load common.sh in their own processes and never share an answer (strace by pid)
test_a_commit_runs_uname_s_once_per_hook_process_and_never_uname_m() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    uc_counter || return 1
    uc_commit counted || return 1
    assert_eq "$(uc_count -s)" 4 "one uname -s for the supervisor, the worker and each of the two scanner runners"
    assert_eq "$(uc_count -m)" 0 "the hook never asks for the architecture"
}

# ^ security a value in the environment is never trusted; the entry points start from nothing => a different platform answer is read again
test_an_inherited_value_is_not_trusted_by_the_cli_or_the_hook() {
    lc_begin && lc_make_fixtures && lc_use_fixtures && uc_counter || return 1
    set_env GSG_UNAME_S=MINGW64_NT-10.0-26200 GSG_UNAME_M=riscv64
    gsg install
    assert_rc 0 "install ignores the inherited answers"
    assert_eq "$(uc_count -s)" 1 "the CLI asked uname -s itself"
    assert_eq "$(uc_count -m)" 1 "the CLI asked uname -m itself"
    uc_counter || return 1
    uc_commit inherited || return 1
    assert_eq "$(uc_count -s)" 4 "the hook asked uname -s itself in each of its four processes"
}

# ^ invariant doctor checks each scanner against the pin of this platform; the architecture is asked once, not once per scanner
test_doctor_runs_uname_m_once_not_once_per_scanner() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    uc_counter || return 1
    gsg doctor
    assert_eq "$(uc_count -m)" 1 "uname -m runs once for the whole doctor run"
    assert_eq "$(uc_count -s)" 1 "uname -s runs once for the whole doctor run"
}

run_file_tests
