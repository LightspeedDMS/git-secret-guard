#!/usr/bin/env bash
# ^ invariant the hook command starts hooks/secret-scan with the bash the install recorded, never with the one the script's shebang finds (#28, #31)
# ^ external Windows runs the same tests; the stand-in is a script named bash, never the real System32 bash.exe (WSL) and never wsl.exe
# ^ why no stand-in named bash.exe, not both; a script cannot be an .exe and an msys env may not start one, the control step proves the script is reached
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

STANDIN_LOG=""

# ^ invariant a script named bash records its call and exits 0 => started through the shebang, the hook never ran and the commit passed
rb_standin_first_on_path() {
    mkdir -p -- "$SANDBOX/shadow-bash" || return 1
    STANDIN_LOG="$SANDBOX/standin-bash.called"
    rm -f -- "$STANDIN_LOG"
    printf '#!/bin/sh\n: >"%s"\nexit 0\n' "$STANDIN_LOG" >"$SANDBOX/shadow-bash/bash" || return 1
    chmod 755 -- "$SANDBOX/shadow-bash/bash" || return 1
    set_env PATH="$SANDBOX/shadow-bash:$SANDBOX/pathbin:$TEST_BASE_PATH"
}

# ^ invariant install and the CLI start through env bash => they run with the plain lifecycle PATH, never with the stand-in first
rb_plain_path() { set_env PATH="$SANDBOX/pathbin:$TEST_BASE_PATH"; }

rb_setting() { sed -n "s/^$1=//p" "$LC_DATA/settings"; }

rb_install() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
}

test_install_records_the_bash_that_runs_it_and_names_it_in_the_hook_command() {
    local want shown cmd
    rb_install || return 1
    want="$(lc_recorded_bash)" || return 1
    assert_eq "$(rb_setting BASH_BIN)" "$(printf '%q' "$want")" "the settings record the bash that ran install"
    shown="$want"
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then shown="$(cygpath -m "$want")"; fi
    cmd="$(gitx config --global --get hook.git-secret-guard.command)" || return 1
    assert_contains "$cmd" "[ -f '$shown' ] && [ -x '$shown' ] || " "the command checks the recorded bash first"
    assert_contains "$cmd" "exec '$shown' '$(git_path "$LC_DATA")/hooks/secret-scan'" "and starts the hook with it"
}

test_a_bash_found_on_path_is_never_started_after_install() {
    rb_install || return 1
    rb_standin_first_on_path || return 1
    new_repo standin || return 1
    stage_file a.txt one || return 1
    commit_cap "after install"
    assert_no_file "$STANDIN_LOG" "the stand-in bash on PATH was never started"
    assert_contains "$ERR" "git-secret-guard:" "the hook ran (the fixture scanners are not real, so it blocks)"
    assert_rc 1 "blocked, not passed in silence"
}

# ^ why the command is built for a missing bash, not a removed link; under MSYS a link is a copy
# ^ invariant the message shows the path in the form the command holds it, the mixed C:/ form on Windows (git_path)
test_a_recorded_bash_that_is_gone_blocks_with_our_message_and_starts_nothing() {
    rb_install || return 1
    local cmd
    cmd="$(lc_hook_command "$LC_DATA" "$SANDBOX/gone/bash")" || return 1
    gitx config --global --replace-all hook.git-secret-guard.command "$cmd" || return 1
    rb_standin_first_on_path || return 1
    new_repo gone || return 1
    stage_file a.txt one || return 1
    commit_cap "recorded bash gone"
    assert_rc 1 "blocked"
    assert_contains "$ERR" "git-secret-guard: cannot start the bash the install recorded ($(git_path "$SANDBOX/gone/bash")); nothing was scanned; run git-secret-guard install" "our message"
    assert_no_file "$STANDIN_LOG" "the stand-in bash on PATH was never started"
}

test_an_install_that_predates_the_recorded_bash_is_upgraded_by_the_next_install() {
    rb_install || return 1
    local cmd bare want
    want="$(lc_recorded_bash)" || return 1
    bare="$(git_path "$LC_DATA")/hooks/secret-scan"
    # ^ why rewritten by hand, not a checkout of the old release; an old install is exactly this pair, no BASH_BIN line and the bare hook path
    sed -i '/^BASH_BIN=/d' "$LC_DATA/settings" || return 1
    gitx config --global --replace-all hook.git-secret-guard.command "$bare" || return 1
    new_repo window || return 1
    stage_file a.txt one || return 1
    commit_cap "old command, new share"
    assert_contains "$ERR" "git-secret-guard:" "the old bare command still reaches the hook (never a silent pass)"
    assert_rc 1 "blocked by the fixture scanners, the hook ran"
    # ^ why a control step, not only the after check; the old command must start the stand-in, else its absence later proves nothing here
    rb_standin_first_on_path || return 1
    new_repo control || return 1
    stage_file c.txt three || return 1
    commit_cap "old command, stand-in first"
    assert_file "$STANDIN_LOG" "control: the old command starts the stand-in bash (the bug, shown on this platform)"
    assert_rc 0 "control: and the commit passes unscanned"
    rb_plain_path
    gsg install
    assert_rc 0 "the flagless install an auto-update runs"
    assert_eq "$(rb_setting BASH_BIN)" "$(printf '%q' "$want")" "BASH_BIN is recorded now"
    cmd="$(gitx config --global --get hook.git-secret-guard.command)" || return 1
    assert_contains "$cmd" "exec '" "the command is the new form"
    rb_standin_first_on_path || return 1
    new_repo upgraded || return 1
    stage_file b.txt two || return 1
    commit_cap "after the upgrade"
    assert_no_file "$STANDIN_LOG" "the stand-in bash on PATH was never started"
    assert_rc 1 "scanned (the fixture scanners block)"
}

test_a_relative_recorded_bash_is_refused_by_the_command_text_status_and_doctor() {
    rb_install || return 1
    local text rc
    text="$(lc_hook_command "$LC_DATA" bash 2>&1)"
    rc=$?
    assert_eq "$rc" 1 "no command is written for a relative bash"
    assert_contains "$text" "the recorded bash must be an absolute path, got [bash]" "and it says why"
    assert_not_contains "$text" "[ -f" "no half command is printed"
    if [ "$TEST_IS_WINDOWS" -eq 0 ]; then
        text="$(lc_hook_command "$LC_DATA" 'C:/Program Files/Git/usr/bin/bash.exe' 2>&1)"
        rc=$?
        assert_eq "$rc" 1 "a drive-letter path is relative off Windows"
        assert_contains "$text" "the recorded bash must be an absolute path, got [C:/Program Files/Git/usr/bin/bash.exe]" "and is refused"
    fi
    sed -i "s#^BASH_BIN=.*#BASH_BIN=bash#" "$LC_DATA/settings" || return 1
    gsg status
    assert_rc 1 "status fails"
    assert_contains "$OUT" "bash: MISMATCH (bash must be an absolute path, got [bash]; the hook command cannot be written with it" "the bash line"
    assert_contains "$OUT" "global config: MISMATCH (the wanted command cannot be built" "and the config line"
    gsg doctor --roots "$SANDBOX"
    assert_rc 2 "doctor cannot run"
    assert_contains "$ERR" "the recorded bash must be an absolute path, got [bash]" "and says why"
}

run_file_tests
