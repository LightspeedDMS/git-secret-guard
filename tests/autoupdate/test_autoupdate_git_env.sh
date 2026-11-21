#!/usr/bin/env bash
# shellcheck shell=bash
# ^ invariant a caller's repository variables never steer the update cycle, and its fetch never waits for a person
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/autoupdate/autoupdate.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/autoupdate.sh"

AU_TEMPLATE=1

# ^ invariant au_fetch_standin makes the settings name a timeout recording the fetch call only, its arguments and the one variable GIT_TERMINAL_PROMPT
# ^ why one variable, not the whole environment; a dump could print a real key, and the arguments already show the launcher
au_fetch_standin() {
    # shellcheck disable=SC2016
    printf '#!/bin/sh\ncase " $* " in *" fetch "*) printf "%%s prompt=%%s\\n" "$*" "${GIT_TERMINAL_PROMPT-unset}" >>"%s" ;; esac\nexec %s "$@"\n' \
        "$SANDBOX/au-fetch.log" "$TEST_TIMEOUT" >"$SANDBOX/au-fetch-timeout" || return 1
    chmod 755 "$SANDBOX/au-fetch-timeout" || return 1
    : >"$SANDBOX/au-fetch.log" || return 1
    printf 'TIMEOUT_BIN=%q\n' "$SANDBOX/au-fetch-timeout" >>"$LC_DATA/settings"
}

# ^ security GIT_DIR and GIT_WORK_TREE of a calling hook name another repository => the cycle still updates its own checkout and leaves the other alone
test_a_callers_git_dir_and_work_tree_do_not_steer_the_cycle() {
    local other="$SANDBOX/au-other" refs_before head_before
    au_setup_with_release || return 1
    gitx init -q "$other" || return 1
    printf 'other\n' >"$other/file" || return 1
    gitx -C "$other" add -- file && gitx -C "$other" -c user.name=Other -c user.email=other@example.invalid commit -q --no-verify -m other || return 1
    refs_before="$(gitx -C "$other" for-each-ref)" || return 1
    head_before="$(gitx -C "$other" rev-parse HEAD)" || return 1
    local -a saved_env=("${EXTRA_ENV[@]}")
    set_env "GIT_DIR=$other/.git" "GIT_WORK_TREE=$other"
    upd
    EXTRA_ENV=("${saved_env[@]}")
    assert_rc 0 "update with a foreign GIT_DIR and GIT_WORK_TREE"
    assert_record updated "" "the cycle updated"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.1.0 "installed 1.1.0"
    assert_eq "$(gitx -C "$AU_CO" rev-parse HEAD)" "$(gitx -C "$AU_CO" rev-parse 'refs/tags/v1.1.0^{commit}')" "its own checkout moved to the tag"
    assert_eq "$(gitx -C "$other" for-each-ref)" "$refs_before" "the foreign repository's refs are untouched"
    assert_eq "$(gitx -C "$other" rev-parse HEAD)" "$head_before" "the foreign repository's HEAD is untouched"
    assert_eq "$(gitx -C "$other" status --porcelain)" "" "the foreign work tree is clean"
}

# ^ external Windows has no setsid and its fetch is bounded by timeout alone (test_autoupdate_windows.sh)
test_the_fetch_runs_under_setsid_with_the_terminal_prompt_off() {
    local line recorded
    if [ "$TEST_IS_WINDOWS" -eq 1 ] || [ -z "$TEST_SETSID" ]; then skip_test "no setsid on this host; the Windows fetch has its own test"; fi
    au_setup_with_release || return 1
    au_fetch_standin || return 1
    set_env GIT_TERMINAL_PROMPT=1
    upd
    assert_rc 0 "update"
    assert_record updated "" "the cycle updated"
    line="$(<"$SANDBOX/au-fetch.log")"
    assert_eq "$(printf '%s\n' "$line" | wc -l | tr -d ' ')" 1 "the fetch was recorded once"
    recorded="$(sed -n 's/^SETSID_BIN=//p' "$LC_DATA/settings")"
    assert_file "$recorded" "the settings record a setsid"
    assert_contains "$line" " $recorded " "the fetch runs under the recorded setsid"
    assert_contains "$line" " fetch " "the recorded call is the fetch"
    assert_contains "$line" " prompt=0" "git is told never to prompt, whatever the caller set"
}

run_file_tests
