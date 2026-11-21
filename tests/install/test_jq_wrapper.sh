#!/usr/bin/env bash
# ^ invariant on Windows JQ_BIN is a wrapper script; its shebang names the recorded bash, never env bash, or a bash first on PATH runs every jq call (#28, #31)
# ^ why Linux-runnable, not Windows only; the wrapper text and the hook run depend only on who owns the shebang
# shellcheck disable=SC2016
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ invariant inst CODE [ARG...] runs CODE in a child with the install library sourced; its $1 is the project, ARG... are its $2...
# ^ invariant WINDOWS=1 in the caller's environment makes the child's uname answer Git for Windows
# shellcheck disable=SC2016
inst() {
    local code
    code='GSG_ROOT="$1"; GSG_NAME=git-secret-guard
uname() { if [ "${1:-}" = -m ]; then echo x86_64; elif [ "$WINDOWS" = 1 ]; then echo MINGW64_NT-10.0-26200; else echo Linux; fi; }
if [ "$WINDOWS" = 1 ]; then cygpath() { printf "%s\n" "${!#}"; }; fi
for lib in platform/brew core/common install/tools install/install inspect/doctor_repos; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
'"$1"
    run_cap env -i "${GSG_ENV[@]}" WINDOWS="${WINDOWS:-0}" bash -c "$code" _ "$GSG_PROJECT" "${@:2}"
}

# ^ invariant fake_bash DIR [BODY] makes DIR and an executable DIR/bash running BODY, default exit 0
fake_bash() {
    mkdir -p -- "$1" && printf '#!/bin/sh\n%s\n' "${2:-exit 0}" >"$1/bash" && chmod 755 -- "$1/bash"
}

test_the_jq_wrapper_names_the_recorded_bash_in_its_shebang() {
    inst 'install_write_jq_wrapper "$2" "$3" "$4"' "$SANDBOX/jqw" /opt/real/jq /usr/bin/bash.exe
    assert_rc 0 "written"
    assert_eq "$(head -n 1 "$SANDBOX/jqw")" "#!/usr/bin/bash.exe" "the shebang is the recorded bash"
    assert_eq "$(sed -n 2p "$SANDBOX/jqw")" 'exec /opt/real/jq -b "$@"' "and the body is unchanged"
}

# ^ hazard a shebang of env bash took the first bash on PATH => the hook ran jq through a stand-in and failed closed, the shebang still choosing
test_a_bash_first_on_path_is_never_started_by_the_jq_wrapper() {
    local standin="$SANDBOX/shadow-bash" log="$SANDBOX/standin-jq.called"
    # ^ why the real scanners, not the stubs; the stub scanners start through env bash themselves and would reach the stand-in
    [ -x "$REAL_TRUFFLEHOG" ] || skip_test "trufflehog not found at $REAL_TRUFFLEHOG"
    [ -x "$REAL_BETTERLEAKS" ] || skip_test "betterleaks not found at $REAL_BETTERLEAKS"
    fake_bash "$standin" ": >\"$log\"" || return 1
    # ^ why jq.exe on Windows, not TEST_JQ; the harness TEST_JQ there is a script, its own shebang could reach the stand-in
    inst 'install_write_jq_wrapper "$2" "$3" "$4"' "$SANDBOX/jqw" "${TEST_JQ_EXE:-$TEST_JQ}" "$TEST_RECORDED_BASH"
    assert_rc 0 "written"
    use_real_tools "JQ_BIN=$SANDBOX/jqw"
    set_env HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 http_proxy=http://127.0.0.1:9
    set_env PATH="$standin:$REAL_HOME/.local/bin:$TEST_BASE_PATH"
    new_repo wrap || return 1
    stage_file src/app.txt hello || return 1
    commit_cap "clean"
    assert_no_file "$log" "the stand-in bash was never started"
    assert_rc 0 "the commit is scanned and passes"
}

test_an_install_refuses_a_recorded_bash_a_shebang_cannot_hold_on_windows() {
    local record='BASH="$2"; install_record_bash; echo "rc=$? bin=[$INSTALL_BASH_BIN]"' spaced="$SANDBOX/a dir with spaces" long
    long="$SANDBOX/$(printf 'd%.0s' {1..60})/$(printf 'e%.0s' {1..60})"
    fake_bash "$spaced" && fake_bash "$long" || return 1
    WINDOWS=1 inst "$record" "$spaced/bash"
    assert_contains "$OUT" "rc=1 bin=[]" "refused, nothing recorded"
    assert_contains "$ERR" "a shebang cannot hold it (whitespace)" "says why"
    WINDOWS=1 inst "$record" "$long/bash"
    assert_contains "$OUT" "rc=1 bin=[]" "a path longer than a shebang holds is refused too"
    assert_contains "$ERR" "a shebang cannot hold it (longer than 100 characters)" "says why"
    inst "$record" "$spaced/bash"
    assert_contains "$OUT" "rc=0" "off Windows no wrapper exists and the same path is fine"
}

# ^ hazard after the hook's exec of a mixed path, $BASH on Windows is C:/Program Files/...; a shebang cannot hold the space, the POSIX form can
# ^ external cygpath is faked to answer the POSIX form of a real file; the real one answers /usr/bin/bash.exe for Git for Windows' own bash
test_install_takes_a_mixed_form_windows_bash_in_posix_form() {
    fake_bash "$SANDBOX/usr/bin" || return 1
    WINDOWS=1 inst 'FAKE="$3"; cygpath() { printf "%s\n" "$FAKE"; }; BASH="$2"; install_record_bash; echo "rc=$? bin=[$INSTALL_BASH_BIN]"' \
        "C:/Program Files/Git/usr/bin/bash.exe" "$SANDBOX/usr/bin/bash"
    assert_contains "$OUT" "rc=0 bin=[$SANDBOX/usr/bin/bash]" "the POSIX form is recorded, the spaced mixed form is not refused"
}

test_the_doctor_shim_takes_a_mixed_form_windows_bash_in_posix_form() {
    fake_bash "$SANDBOX/usr/bin" || return 1
    WINDOWS=1 inst 'FAKE="$4"; cygpath() { printf "%s\n" "$FAKE"; }; BASH="$2"; DR_WORK="$3"; DR_TIMEOUT_OK=1; DR_LIMIT=5; TIMEOUT_BIN=/usr/bin/timeout; GSG_GIT=/usr/bin/git; doctor_bound_git; echo "rc=$?"' \
        "C:/Program Files/Git/usr/bin/bash.exe" "$SANDBOX/drw4" "$SANDBOX/usr/bin/bash"
    assert_contains "$OUT" "rc=0" "the shim is written"
    assert_eq "$(head -n 1 "$SANDBOX/drw4/bin/git")" "#!$SANDBOX/usr/bin/bash" "with the POSIX form in its shebang"
}

# ^ hazard the doctor git shim ran through env bash too; doctor also runs in the hook's coverage re-check, where a stand-in bash would answer for git
test_the_doctor_git_shim_names_the_bash_running_doctor() {
    local run='DR_WORK="$2"; DR_TIMEOUT_OK="$3"; DR_LIMIT=5; TIMEOUT_BIN=/usr/bin/timeout; GSG_GIT=/usr/bin/git; doctor_bound_git; echo "rc=$? bash=$BASH"'
    inst "$run" "$SANDBOX/drw1" 1
    assert_contains "$OUT" "rc=0 bash=" "the shim is written"
    assert_eq "$(head -n 1 "$SANDBOX/drw1/bin/git")" "#!${OUT#*bash=}" "the timeout shim starts with the bash running doctor"
    inst "$run" "$SANDBOX/drw2" 0
    assert_eq "$(head -n 1 "$SANDBOX/drw2/bin/git")" "#!${OUT#*bash=}" "so does the shim of an unusable timeout"
}

test_a_bash_a_shebang_cannot_hold_stops_the_doctor_git_shim() {
    fake_bash "$SANDBOX/two words" || return 1
    inst 'BASH="$2"; DR_WORK="$3"; DR_TIMEOUT_OK=1; DR_LIMIT=5; TIMEOUT_BIN=/usr/bin/timeout; GSG_GIT=/usr/bin/git; doctor_bound_git; echo "rc=$?"' "$SANDBOX/two words/bash" "$SANDBOX/drw3"
    assert_contains "$OUT" "rc=1" "no shim is written"
    assert_contains "$ERR" "a shebang cannot hold it (whitespace)" "and the reason is said"
}

# ^ invariant both writes of the wrapper in install_copy_share pass the recorded bash => every install runs it, an older install is upgraded by the next one
test_every_install_path_rewrites_the_wrapper_with_the_recorded_bash() {
    local n
    n="$(grep -c 'install_write_jq_wrapper "[^"]*" "\$INSTALL_JQ_BIN" "\$INSTALL_BASH_BIN"' "$GSG_PROJECT/lib/install/install.sh")"
    assert_eq "$n" 2 "both the in-place and the new-tree write pass the recorded bash"
}

run_file_tests
