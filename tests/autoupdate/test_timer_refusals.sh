#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup.sh"

# ^ coupled the wording of the timer and LaunchAgent refusals after the git upgrade changed something; the sandbox is the one of the git upgrade tests

# shellcheck disable=SC2016
test_the_timer_and_launchd_refusals_use_the_changed_wording() {
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "Linux package manager flows"; fi
    gu_rpm_setup || return 1
    set_env GIT_CONFIG_GLOBAL=rel.cfg
    gu_run 'source "$GSG_ROOT/lib/autoupdate/timer.sh"; source "$GSG_ROOT/lib/platform/launchd.sh"; paths_init || exit 8
        GITUP_CHANGED="git 2.56.0"
        timer_check_config_global
        timer_check_values "/tmp/bad%dir"
        mkdir -p "$GSG_UNIT_DIR" && printf "not ours\n" >"$GSG_UNIT_DIR/$GSG_TIMER_UNIT"
        timer_check_target /tmp
        ctl="$(printf "/tmp/a\001b")"
        launchd_check_values "$ctl"
        mkdir -p "${GSG_AGENT_PLIST%/*}" && printf "not ours\n" >"$GSG_AGENT_PLIST"
        launchd_check_target /tmp
        true'
    assert_not_contains "$ERR" "nothing was changed" "no refusal after a change claims nothing changed"
    assert_eq "$(grep -c 'the only change made was the git upgrade' <<<"$ERR")" "5" "all five say what changed"
}

run_file_tests
