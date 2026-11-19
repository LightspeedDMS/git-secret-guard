#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/autoupdate_units.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/autoupdate_units.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup.sh"

# ^ external Windows has no systemd => install --auto-update is refused there until its own story
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="systemd user units, Windows has no systemd"; fi

test_install_auto_update_records_the_checkout_and_enables_the_update_timer() {
    local service timer
    au_begin || return 1
    printf '#!/bin/sh\necho "$*" >>"%s/loginctl.log"\n' "$SANDBOX" >"$SANDBOX/pathbin/loginctl" && chmod 755 "$SANDBOX/pathbin/loginctl" || return 1
    gsg_from co install --auto-update
    assert_rc 0 "install --auto-update"
    assert_eq "$(state_value auto_update)" yes "the state records auto-update"
    assert_eq "$(state_value source_checkout)" "$AU_CO" "and the checkout install ran from"
    assert_eq "$(state_value timer_installed)" no "the doctor timer was not asked for"
    service="$(<"$(unit_dir)/$UPD_SERVICE")"
    timer="$(<"$(unit_dir)/$UPD_TIMER")"
    assert_eq "${service%%$'\n'*}" "$UPD_MARKER" "the service carries its own marker"
    assert_eq "${timer%%$'\n'*}" "$UPD_MARKER" "the timer carries its own marker"
    assert_eq "$(grep '^ExecStart=' "$(unit_dir)/$UPD_SERVICE")" "ExecStart=\"$LC_DATA/bin/git-secret-guard\" update" "the service runs exactly update from the installed copy"
    assert_contains "$service" 'Type=oneshot' "a one-shot service"
    assert_contains "$service" 'Environment="PATH='"$(lc_first_git_dir)"':' "with the PATH of the git that install found first"
    assert_contains "$timer" $'\nOnBootSec=5min\n' "five minutes after boot"
    assert_contains "$timer" $'\nOnUnitActiveSec=1h\n' "then hourly"
    assert_contains "$timer" $'\nUnit='"$UPD_SERVICE"$'\n' "it starts the update service"
    assert_contains "$timer" 'WantedBy=timers.target' "installable"
    assert_eq "$(systemctl_log)" "$PROBE_CALL"$'\n'"--user enable --now $UPD_TIMER" "the manager probe, then the enable"
    assert_no_file "$(unit_dir)/$SERVICE" "no doctor service without --with-timer"
    assert_no_file "$(unit_dir)/$TIMER" "no doctor timer without --with-timer"
    assert_contains "$(<"$LC_DATA/settings")" "SYSTEMCTL_BIN=$SANDBOX/pathbin/systemctl" "the settings record systemctl"
    assert_contains "$OUT" "loginctl enable-linger" "the linger hint is printed"
    assert_no_file "$SANDBOX/loginctl.log" "and linger is not enabled by install"
    assert_no_file "$LC_STATE/update.lock" "the update lock is released"
}

test_both_flags_install_both_unit_pairs() {
    au_install --auto-update --with-timer || return 1
    assert_file "$(unit_dir)/$SERVICE" "doctor service"
    assert_file "$(unit_dir)/$TIMER" "doctor timer"
    assert_file "$(unit_dir)/$UPD_SERVICE" "update service"
    assert_file "$(unit_dir)/$UPD_TIMER" "update timer"
    assert_eq "$(state_value timer_installed)" yes "the doctor timer is recorded"
    assert_eq "$(state_value auto_update)" yes "auto-update is recorded"
    assert_contains "$(systemctl_log)" "--user enable --now $TIMER" "the doctor timer is enabled"
    assert_contains "$(systemctl_log)" "--user enable --now $UPD_TIMER" "the update timer is enabled"
}

test_the_update_units_pass_systemd_analyze_verify() {
    local reason
    command -v systemd-analyze >/dev/null 2>&1 || skip_test "systemd-analyze is not available"
    reason="$(analyze_blocked_reason)"
    if [ -n "$reason" ]; then skip_test "$reason"; fi
    au_install --auto-update || return 1
    verify_update_units
    assert_rc 0 "systemd-analyze --user verify"
    assert_empty "$OUT$ERR" "and it has no complaint"
}

test_a_plain_install_from_a_checkout_records_it_and_writes_no_update_unit() {
    au_install || return 1
    assert_eq "$(state_value source_checkout)" "$AU_CO" "the checkout is recorded"
    assert_eq "$(state_value auto_update)" no "auto-update is off"
    assert_no_file "$LC_HOME/.config" "no unit directory is created"
    assert_empty "$(systemctl_log)" "systemctl was not called"
    assert_not_contains "$OUT" "loginctl" "no linger hint"
    assert_not_contains "$(<"$LC_DATA/settings")" "SYSTEMCTL_BIN" "and the settings hold no systemctl"
    assert_no_file "$LC_STATE/update.lock" "no lock is left behind"
}

test_a_later_plain_install_keeps_auto_update_and_refreshes_the_units_without_enabling() {
    local want
    au_install --auto-update || return 1
    want="$(<"$(unit_dir)/$UPD_SERVICE")"
    printf '# edited by hand\n' >>"$(unit_dir)/$UPD_SERVICE" || return 1
    au_reset_systemctl_log
    gsg_from co install
    assert_rc 0 "plain install over auto-update"
    assert_eq "$(state_value auto_update)" yes "auto-update stays recorded"
    assert_eq "$(state_value source_checkout)" "$AU_CO" "the checkout is recorded from this install"
    assert_eq "$(<"$(unit_dir)/$UPD_SERVICE")" "$want" "a changed unit of ours is rewritten"
    assert_empty "$(systemctl_log)" "without any systemctl call"
    assert_contains "$OUT" "updated the auto-update timer units in $(unit_dir)" "the output says what was rewritten"
    assert_contains "$OUT" "systemctl --user daemon-reload" "and how to make systemd notice"
    assert_not_contains "$OUT" "timer enabled" "it does not claim it enabled anything"
    assert_not_contains "$OUT$ERR" "now follows" "the checkout did not change"
    assert_contains "$(<"$LC_DATA/settings")" "SYSTEMCTL_BIN=" "the settings keep systemctl for uninstall"
}

# ^ invariant only --auto-update enables; a plain install never depends on systemctl, a machine without it can still upgrade the hook
test_a_plain_install_over_auto_update_does_not_need_systemctl() {
    local before
    au_install --auto-update || return 1
    before="$(grep '^SYSTEMCTL_BIN=' "$LC_DATA/settings")" || return 1
    lc_path_without systemctl || return 1
    gsg_from co install
    assert_rc 0 "plain install with no systemctl on PATH"
    assert_not_contains "$ERR" "--auto-update" "no --auto-update wording"
    assert_eq "$(state_value auto_update)" yes "auto-update stays recorded"
    assert_eq "$(grep '^SYSTEMCTL_BIN=' "$LC_DATA/settings")" "$before" "and the recorded systemctl stays in the settings"
}

test_the_test_interval_is_announced_and_written_into_the_timer() {
    au_begin || return 1
    set_env GSG_TEST_UPDATE_INTERVAL_SECONDS=20
    gsg_from co install --auto-update
    assert_rc 0 "install --auto-update with the test interval"
    assert_contains "$ERR" "TEST OVERRIDE active (GSG_TEST_UPDATE_INTERVAL_SECONDS=[20])" "the override is announced on stderr"
    assert_contains "$(<"$(unit_dir)/$UPD_TIMER")" $'\nOnUnitActiveSec=20s\n' "the timer fires every 20 seconds"
    assert_not_contains "$(<"$(unit_dir)/$UPD_TIMER")" "OnUnitActiveSec=1h" "and not hourly"
}

# ^ invariant only the update service names the test interval, and only when install ran with it; the doctor service never does
test_the_update_service_carries_the_test_interval_only_when_it_is_set() {
    au_install --auto-update --with-timer || return 1
    assert_not_contains "$(<"$(unit_dir)/$UPD_SERVICE")" "GSG_TEST_UPDATE_INTERVAL_SECONDS" "without the variable the update service does not name it"
    set_env GSG_TEST_UPDATE_INTERVAL_SECONDS=20
    gsg_from co install --auto-update --with-timer
    assert_rc 0 "install with the test interval"
    assert_contains "$(<"$(unit_dir)/$UPD_SERVICE")" $'\nEnvironment="GSG_TEST_UPDATE_INTERVAL_SECONDS=20"\nExecStart=' "the update service carries it, after the other variables"
    assert_not_contains "$(<"$(unit_dir)/$SERVICE")" "GSG_TEST_UPDATE_INTERVAL_SECONDS" "the doctor service never does"
}

# ^ coupled update starts its child install with the environment of the update service; the test takes the variable from the unit, as systemd would
test_an_install_with_the_interval_of_the_service_keeps_the_timer() {
    local line service timer
    au_begin || return 1
    set_env GSG_TEST_UPDATE_INTERVAL_SECONDS=20
    gsg_from co install --auto-update
    assert_rc 0 "install --auto-update with the test interval"
    service="$(<"$(unit_dir)/$UPD_SERVICE")"
    timer="$(<"$(unit_dir)/$UPD_TIMER")"
    line="$(grep '^Environment="GSG_TEST_UPDATE_INTERVAL_SECONDS=' "$(unit_dir)/$UPD_SERVICE")" || fail "the update service has no line for the test interval"
    line="${line#Environment=\"}"
    EXTRA_ENV=()
    set_env "${line%\"}"
    gsg_from co install
    assert_rc 0 "the plain install an update run starts"
    assert_eq "$(<"$(unit_dir)/$UPD_TIMER")" "$timer" "the timer keeps its 20 seconds"
    assert_contains "$timer" $'\nOnUnitActiveSec=20s\n' "the 20 seconds the first install wrote"
    assert_eq "$(<"$(unit_dir)/$UPD_SERVICE")" "$service" "the service is unchanged, the next run inherits the interval again"
    assert_not_contains "$OUT" "updated the auto-update timer units" "nothing was rewritten"
    EXTRA_ENV=()
    gsg_from co install
    assert_rc 0 "a plain install without the variable"
    assert_contains "$(<"$(unit_dir)/$UPD_TIMER")" $'\nOnUnitActiveSec=1h\n' "goes back to the hour"
    assert_not_contains "$(<"$(unit_dir)/$UPD_SERVICE")" "GSG_TEST_UPDATE_INTERVAL_SECONDS" "and the service no longer names the variable"
}

test_a_test_interval_that_is_not_a_number_is_refused_before_any_change() {
    au_begin || return 1
    set_env GSG_TEST_UPDATE_INTERVAL_SECONDS=20s
    gsg_from co install --auto-update
    assert_rc 1 "a value that is not a plain number of seconds"
    assert_contains "$ERR" "GSG_TEST_UPDATE_INTERVAL_SECONDS" "named"
    assert_contains "$ERR" "nothing was changed" "with the claim"
    assert_nothing_installed "bad interval"
}

test_an_unreachable_user_manager_is_refused_before_any_change() {
    au_begin || return 1
    au_fail_systemctl show || return 1
    gsg_from co install --auto-update
    assert_rc 1 "systemctl --user cannot reach the manager"
    assert_contains "$ERR" "systemd user manager" "says what cannot be reached"
    assert_contains "$ERR" "Failed: injected systemctl failure" "with systemctl's own first line"
    assert_contains "$ERR" "nothing was changed" "and the claim"
    assert_eq "$(systemctl_log)" "$PROBE_CALL" "only the probe ran"
    assert_nothing_installed "unreachable manager"
    assert_no_file "$(unit_dir)" "no unit directory"
}

test_an_install_from_another_checkout_says_which_one_auto_update_now_follows() {
    local other
    au_install --auto-update || return 1
    au_copy coB git || return 1
    other="$(realpath -- "$SANDBOX/coB")" || return 1
    gsg_from coB install
    assert_rc 0 "plain install from B"
    assert_eq "$(state_value source_checkout)" "$other" "B is recorded"
    assert_eq "$(state_value auto_update)" yes "auto-update stays on"
    assert_contains "$OUT" "auto-update now follows $other" "and install says so"
}

test_an_install_from_a_copy_that_is_no_checkout_keeps_the_recorded_checkout() {
    au_install --auto-update || return 1
    gsg_installed install
    assert_rc 0 "install run from the share dir"
    assert_eq "$(state_value source_checkout)" "$AU_CO" "the recorded checkout is kept"
    assert_eq "$(state_value auto_update)" yes "and auto-update with it"
    assert_not_contains "$OUT$ERR" "now follows" "nothing changed, nothing is announced"
    au_copy export || return 1
    gsg_from export install
    assert_rc 0 "install run from a tag export"
    assert_eq "$(state_value source_checkout)" "$AU_CO" "still the recorded checkout"
}

test_auto_update_from_a_copy_that_is_no_checkout_uses_the_recorded_checkout() {
    au_install || return 1
    gsg_installed install --auto-update
    assert_rc 0 "install --auto-update from the share dir"
    assert_eq "$(state_value auto_update)" yes "auto-update is on"
    assert_eq "$(state_value source_checkout)" "$AU_CO" "following the recorded checkout"
    assert_file "$(unit_dir)/$UPD_TIMER" "the units are written"
}

test_an_unreachable_user_manager_leaves_an_existing_install_untouched() {
    local state settings
    au_install || return 1
    state="$(<"$LC_STATE/state")" || return 1
    settings="$(<"$LC_DATA/settings")" || return 1
    au_fail_systemctl show || return 1
    gsg_from co install --auto-update
    assert_rc 1 "refused"
    assert_eq "$(<"$LC_STATE/state")" "$state" "the state is unchanged"
    assert_eq "$(<"$LC_DATA/settings")" "$settings" "the settings are unchanged"
    assert_no_file "$(unit_dir)" "no unit was written"
    assert_no_file "$LC_STATE/update.lock" "no lock is left behind"
}

test_auto_update_refuses_before_any_change_when_systemctl_is_missing() {
    au_begin || return 1
    lc_path_without systemctl || return 1
    gsg_from co install --auto-update
    assert_rc 1 "no systemctl on PATH"
    assert_contains "$ERR" "systemctl is required for --auto-update but was not found on PATH; nothing was changed" "says why, naming the flag"
    assert_not_contains "$ERR" "--with-timer" "and not the other flag"
    assert_nothing_installed "no systemctl"
}

test_update_units_that_install_did_not_write_are_never_overwritten() {
    au_begin || return 1
    mkdir -p -- "$(unit_dir)" && printf '[Timer]\nOnCalendar=daily\n' >"$(unit_dir)/$UPD_TIMER" || return 1
    gsg_from co install --auto-update
    assert_rc 1 "a foreign unit with the update timer's name"
    assert_contains "$ERR" "$(unit_dir)/$UPD_TIMER exists and was not written by git-secret-guard; move it away and run install again; nothing was changed" "says whose it is"
    assert_eq "$(<"$(unit_dir)/$UPD_TIMER")" $'[Timer]\nOnCalendar=daily' "the file is untouched"
    assert_no_file "$LC_STATE" "and nothing else was installed"
    assert_no_file "$LC_DATA" "no share dir"
    assert_not_contains "$(systemctl_log)" "enable" "nothing was enabled"
}

# ^ invariant a doctor unit carries the --with-timer marker => at an update unit path it is not ours
test_a_unit_with_the_doctor_marker_at_an_update_unit_path_is_not_ours() {
    au_begin || return 1
    mkdir -p -- "$(unit_dir)" || return 1
    printf '%s\n' '# generated by git-secret-guard install --with-timer; uninstall removes this file' '[Service]' >"$(unit_dir)/$UPD_SERVICE" || return 1
    gsg_from co install --auto-update
    assert_rc 1 "the wrong marker"
    assert_contains "$ERR" "$(unit_dir)/$UPD_SERVICE exists and was not written by git-secret-guard" "refused"
    assert_no_file "$LC_STATE" "nothing was installed"
}

test_a_value_a_unit_cannot_carry_is_refused_with_auto_update_before_any_change() {
    au_begin || return 1
    mkdir -p -- "$SANDBOX/xdg/a%b" || return 1
    set_env XDG_DATA_HOME="$SANDBOX/xdg/a%b"
    gsg_from co install --auto-update
    assert_rc 1 "a % in the share path"
    assert_contains "$ERR" "cannot be written into a systemd unit" "named"
    assert_no_file "$LC_STATE" "nothing was installed"
    assert_no_file "$SANDBOX/xdg/a%b/git-secret-guard" "no share dir"
}

test_auto_update_without_any_checkout_is_refused_before_any_change() {
    au_begin && au_copy export || return 1
    gsg_from export install --auto-update
    assert_rc 1 "no recorded checkout, and this copy is not one"
    assert_contains "$ERR" "--auto-update needs a git checkout" "says what is missing"
    assert_contains "$ERR" "nothing was changed" "with the claim"
    assert_nothing_installed "no checkout"
    assert_not_contains "$(systemctl_log)" "enable" "nothing was enabled"
}

test_auto_update_is_refused_on_wsl_without_systemd_and_the_text_names_the_flag() {
    au_begin || return 1
    printf '%s\n' '5.15.153.1-microsoft-standard-WSL2' >"$SANDBOX/osrelease" || return 1
    set_env GSG_WSL_OSRELEASE="$SANDBOX/osrelease"
    gsg_from co install --auto-update
    assert_rc 1 "WSL 2 without systemd"
    assert_contains "$ERR" "--auto-update needs systemd, and it is not running in this WSL distribution; nothing was changed" "the WSL text names --auto-update"
    assert_contains "$ERR" "/etc/wsl.conf" "with the fix"
    assert_not_contains "$ERR" "--with-timer" "and never the other flag"
    assert_nothing_installed "WSL 2"
    printf '%s\n' '4.4.0-17763-Microsoft' >"$SANDBOX/osrelease" || return 1
    gsg_from co install --auto-update
    assert_rc 1 "WSL 1"
    assert_contains "$ERR" "--auto-update is not available on WSL 1" "the WSL 1 text names --auto-update"
    assert_contains "$ERR" "git-secret-guard update by hand" "and the command to run by hand"
    assert_not_contains "$ERR" "--with-timer" "never the other flag"
    assert_not_contains "$ERR" "wsl.conf" "no fix that cannot work on WSL 1"
    assert_nothing_installed "WSL 1"
}

# shellcheck disable=SC2016
test_the_with_timer_wsl_text_is_what_it_was() {
    printf '%s\n' '5.15.153.1-microsoft-standard-WSL2' >"$SANDBOX/osrelease" || return 1
    set_env GSG_WSL_OSRELEASE="$SANDBOX/osrelease" GSG_WSL_INTEROP="$SANDBOX/no-interop" GSG_WSL_SYSTEMD_DIR="$SANDBOX/no-systemd"
    au_lib 'wsl_check_timer 1; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "WSL 2 is refused"
    assert_contains "$ERR" "git-secret-guard: --with-timer needs systemd, and it is not running in this WSL distribution; nothing was changed. Put this in /etc/wsl.conf:" "one argument means --with-timer"
    printf '%s\n' '4.4.0-17763-Microsoft' >"$SANDBOX/osrelease" || return 1
    au_lib 'wsl_check_timer 1; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "WSL 1 is refused"
    assert_contains "$ERR" "git-secret-guard: --with-timer is not available on WSL 1: it has no systemd, and the weekly timer is a systemd user timer; install without --with-timer and run git-secret-guard doctor by hand; nothing was changed" "the WSL 1 text too"
}

test_a_failing_enable_keeps_the_hook_installed_and_a_rerun_finishes() {
    au_begin || return 1
    au_fail_systemctl enable || return 1
    gsg_from co install --auto-update
    assert_rc 1 "systemctl cannot enable the update timer"
    assert_contains "$ERR" "could not enable $UPD_TIMER (systemctl exit 1); the hook is installed and scanning; fix the cause and run install --auto-update again" "says what is true"
    assert_hook_events "the hook config is in place"
    assert_eq "$(state_value auto_update)" yes "the state lets uninstall find the units"
    assert_no_file "$LC_STATE/update.lock" "the lock is released after a failure too"
    rm -f -- "$SANDBOX/systemctl.fail" || return 1
    gsg_from co install --auto-update
    assert_rc 0 "rerun once the cause is fixed"
    assert_contains "$(systemctl_log)" "--user enable --now $UPD_TIMER" "enabled this time"
}

test_install_takes_the_update_lock_and_refuses_while_another_run_holds_it() {
    local state
    au_install || return 1
    state="$(<"$LC_STATE/state")" || return 1
    au_hold_lock || return 1
    gsg_from co install --auto-update
    assert_rc 1 "the update lock is held by a live process"
    assert_contains "$ERR" "$LC_STATE/update.lock" "names the lock"
    assert_contains "$ERR" "run install again" "and what to do"
    assert_eq "$(<"$LC_STATE/state")" "$state" "the state is unchanged"
    assert_no_file "$(unit_dir)" "no unit was written"
    [ -L "$LC_STATE/update.lock" ] || fail "the holder's lock was removed"
    au_drop_lock
    gsg_from co install --auto-update
    assert_rc 0 "once the lock is free install goes through"
}

# ^ coupled update exports GSG_UPDATE_LOCK_PID to its child install; the test shell is the parent here and plays the update run
test_the_child_install_of_an_update_run_is_let_in() {
    au_install || return 1
    ln -s "$BASHPID" "$LC_STATE/update.lock" || return 1
    set_env GSG_UPDATE_LOCK_PID="$BASHPID"
    gsg_from co install
    assert_rc 0 "the lock names the parent and the inherited pid matches"
    rm -f -- "$LC_STATE/update.lock" || return 1
}

test_uninstall_refuses_while_the_update_lock_is_held() {
    au_install --auto-update || return 1
    au_reset_systemctl_log
    au_hold_lock || return 1
    gsg uninstall
    assert_rc 1 "the update lock is held"
    assert_contains "$ERR" "$LC_STATE/update.lock" "names the lock"
    assert_contains "$ERR" "uninstall changed nothing" "and says nothing changed"
    assert_file "$(unit_dir)/$UPD_TIMER" "the units stay"
    assert_file "$LC_DATA/settings" "the share dir stays"
    assert_file "$LC_STATE/state" "the state stays"
    assert_hook_events "the hook config stays"
    assert_empty "$(systemctl_log)" "systemctl was not called"
    au_drop_lock
    gsg uninstall
    assert_rc 0 "once the lock is free uninstall goes through"
}

test_uninstall_removes_the_update_units_the_record_and_the_state_dir() {
    au_install --auto-update || return 1
    printf 'checked_at=2026-11-15T17:00:04Z\nresult=current\n' >"$LC_STATE/update" || return 1
    au_reset_systemctl_log
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(systemctl_log)" $'--user disable --now '"$UPD_TIMER"$'\n--user daemon-reload' "disable first, a reload after the files are gone"
    assert_no_file "$(unit_dir)/$UPD_TIMER" "timer removed"
    assert_no_file "$(unit_dir)/$UPD_SERVICE" "service removed"
    assert_no_file "$LC_DATA" "the share dir is removed"
    assert_no_file "$LC_STATE" "the record and the lock are gone, so the state dir is removed"
    assert_contains "$OUT" "disabled and removed the auto-update timer" "reported"
}

# ^ coupled lib/autoupdate/autoupdate.sh makes update-work.XXXXXX (a directory holding the export) and update-tmp.XXXXXX (the record before its rename)
test_uninstall_removes_what_a_killed_update_run_left() {
    au_install --auto-update || return 1
    mkdir -p -- "$LC_STATE/update-work.Ab12Cd/tree/lib/core" "$LC_STATE/update-work.zZ9_xQ" || return 1
    printf 'x\n' >"$LC_STATE/update-work.Ab12Cd/tree/lib/core/common.sh" || return 1
    printf 'result=current\n' >"$LC_STATE/update-tmp.Qw34Er" || return 1
    printf 'result=current\n' >"$LC_STATE/update" || return 1
    gsg uninstall
    assert_rc 0 "uninstall after a killed update run"
    assert_no_file "$LC_STATE/update-work.Ab12Cd" "the work directory is removed with its content"
    assert_no_file "$LC_STATE/update-tmp.Qw34Er" "the temp record is removed"
    assert_no_file "$LC_STATE" "nothing is left, so the state dir is removed"
    assert_not_contains "$ERR" "left in place" "and nothing is reported as kept"
}

# ^ security only a real directory named update-work.?????? is removed with its content; a link is never followed, a lookalike stays
test_uninstall_leaves_what_only_resembles_an_update_work_dir() {
    au_install --auto-update || return 1
    mkdir -p -- "$SANDBOX/outside" "$LC_STATE/update-work.1234567" "$LC_STATE/my-update-work.abcdef" || return 1
    printf 'keep\n' >"$SANDBOX/outside/precious" || return 1
    ln -s "$SANDBOX/outside" "$LC_STATE/update-work.LinkTo" || return 1
    printf 'keep\n' >"$LC_STATE/update-work.aFile1" || return 1
    printf 'keep\n' >"$LC_STATE/update-tmp.1234567" || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_file "$SANDBOX/outside/precious" "the target of a link is untouched"
    [ -L "$LC_STATE/update-work.LinkTo" ] || fail "a link with the name of a work directory was removed"
    assert_file "$LC_STATE/update-work.aFile1" "a regular file with that name stays"
    [ -d "$LC_STATE/update-work.1234567" ] || fail "a directory with a longer suffix was removed"
    [ -d "$LC_STATE/my-update-work.abcdef" ] || fail "a directory with a longer name was removed"
    assert_file "$LC_STATE/update-tmp.1234567" "a file with a longer suffix stays"
    assert_contains "$ERR" "$LC_STATE/update-work.LinkTo is not a directory an update run made; left in place" "the link is reported"
    assert_contains "$ERR" "$LC_STATE/update-work.aFile1 is not a directory an update run made; left in place" "the file is reported"
    assert_no_file "$LC_STATE/state" "the state itself is removed"
}

test_uninstall_handles_both_unit_pairs_and_the_doctor_timer_as_before() {
    au_install --auto-update --with-timer || return 1
    au_reset_systemctl_log
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$(systemctl_log)" "--user disable --now $UPD_TIMER" "the update timer is disabled"
    assert_contains "$(systemctl_log)" "--user disable --now $TIMER" "the doctor timer is disabled"
    assert_no_file "$(unit_dir)/$UPD_TIMER" "update timer removed"
    assert_no_file "$(unit_dir)/$UPD_SERVICE" "update service removed"
    assert_no_file "$(unit_dir)/$TIMER" "doctor timer removed"
    assert_no_file "$(unit_dir)/$SERVICE" "doctor service removed"
    assert_contains "$OUT" "disabled and removed the weekly doctor timer ($(unit_dir)/$TIMER $(unit_dir)/$SERVICE)" "the doctor line is what it was"
    assert_no_file "$LC_STATE" "the state dir is removed"
}

# ^ external systemctl --user enable links timers.target.wants/<timer> to the unit file; the stand-in does not, the test creates the link
test_uninstall_removes_a_dangling_enable_link_of_the_update_timer() {
    local wants
    au_install --auto-update || return 1
    wants="$(unit_dir)/timers.target.wants"
    mkdir -p -- "$wants" && ln -s "$(unit_dir)/$UPD_TIMER" "$wants/$UPD_TIMER" && ln -s /nonexistent/other.timer "$wants/other.timer" || return 1
    rm -f -- "$(unit_dir)/$UPD_TIMER" "$SANDBOX/systemctl.log" || return 1
    gsg uninstall
    assert_rc 0 "uninstall with the timer file already gone"
    [ ! -L "$wants/$UPD_TIMER" ] || fail "the dangling link to our unit is still there"
    [ -L "$wants/other.timer" ] || fail "a dangling link that points elsewhere was removed"
    assert_no_file "$(unit_dir)/$UPD_SERVICE" "the service is removed"
    assert_contains "$OUT" "removed the dangling enable link $wants/$UPD_TIMER" "reported"
    assert_not_contains "$(systemctl_log)" "disable" "nothing of ours was there to disable"
}

test_uninstall_leaves_an_update_unit_it_did_not_write() {
    au_install --auto-update || return 1
    printf '[Timer]\nOnCalendar=daily\n' >"$(unit_dir)/$UPD_TIMER" || return 1
    au_reset_systemctl_log
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$ERR" "$(unit_dir)/$UPD_TIMER was not written by git-secret-guard; left in place" "reported"
    assert_file "$(unit_dir)/$UPD_TIMER" "and kept"
    assert_not_contains "$(systemctl_log)" "disable" "a unit that is not ours is not disabled"
}

test_a_failing_disable_of_the_update_timer_stops_uninstall_with_everything_in_place() {
    au_install --auto-update || return 1
    au_fail_systemctl disable || return 1
    gsg uninstall
    assert_rc 1 "systemctl cannot disable the timer"
    assert_contains "$ERR" "could not disable $UPD_TIMER (systemctl exit 1); the units, the share dir and the state are kept; fix the cause and run uninstall again" "says what stays"
    assert_file "$(unit_dir)/$UPD_TIMER" "the unit is still there"
    assert_file "$LC_STATE/state" "and the state"
    assert_no_file "$LC_STATE/update.lock" "the lock is released for the rerun"
    rm -f -- "$SANDBOX/systemctl.fail" || return 1
    gsg uninstall
    assert_rc 0 "rerun"
    assert_no_file "$LC_STATE" "all gone"
}

# ^ invariant the text of the doctor units for fixed inputs, taken before the functions were parameterised => --with-timer output is byte-identical
# shellcheck disable=SC2016
test_the_doctor_unit_text_is_byte_identical_to_before() {
    local want_service want_timer
    want_service='# generated by git-secret-guard install --with-timer; uninstall removes this file
[Unit]
Description=git-secret-guard weekly coverage report (doctor)

[Service]
Type=oneshot
TimeoutStartSec=1h
Environment="PATH=/usr/bin:/usr/local/bin:/bin"
Environment="XDG_DATA_HOME=/d"
ExecStart="/x/bin/git-secret-guard" doctor'
    want_timer='# generated by git-secret-guard install --with-timer; uninstall removes this file
[Unit]
Description=git-secret-guard weekly coverage report (doctor)

[Timer]
OnCalendar=weekly
Persistent=true
Unit=git-secret-guard-doctor.service

[Install]
WantedBy=timers.target'
    run_cap env -i bash -c 'GSG_SHARE=/x; XDG_DATA_HOME=/d; source "$1/lib/autoupdate/timer.sh" && timer_service_text /usr/bin' _ "$GSG_PROJECT"
    assert_rc 0 "timer_service_text"
    assert_eq "$OUT" "$want_service" "the doctor service text"
    run_cap env -i bash -c 'GSG_SHARE=/x; source "$1/lib/autoupdate/timer.sh" && timer_timer_text' _ "$GSG_PROJECT"
    assert_rc 0 "timer_timer_text"
    assert_eq "$OUT" "$want_timer" "the doctor timer text"
}

test_with_timer_alone_writes_no_update_unit_and_makes_no_extra_systemctl_call() {
    au_install --with-timer || return 1
    assert_eq "$(systemctl_log)" "--user enable --now $TIMER" "exactly the one call it always made"
    assert_no_file "$(unit_dir)/$UPD_SERVICE" "no update service"
    assert_no_file "$(unit_dir)/$UPD_TIMER" "no update timer"
    assert_eq "$(state_value auto_update)" no "auto-update is off"
    assert_not_contains "$OUT" "loginctl" "no linger hint"
}

test_the_cli_knows_the_flag_and_the_update_command() {
    lc_begin || return 1
    gsg help
    assert_rc 0 "help"
    assert_contains "$OUT" "--auto-update" "help names the flag"
    assert_contains "$OUT" $'\n  update\n' "and the update command"
    gsg update extra
    assert_rc 2 "update takes no arguments"
    assert_contains "$ERR" "update takes no arguments" "says so"
    gsg uninstall --auto-update
    assert_rc 2 "the flag belongs to install only"
}

# ^ coupled lib/install/install.sh:INSTALL_HP_MIN_GIT is 2.26; an older git cannot read the state early => install reads it only after the git offers
AU_GIT_TOO_OLD_FOR_EARLY_CHECKS=2.20.0
# ^ invariant how long the stand-in systemctl of the hang test sleeps; far past the one second au_short_timeout leaves it, short for a run without a bound
AU_HANG_SECONDS=15

# ^ invariant the tree of gu_tree_with_module holds no .git => it is an export, and no state exists; the test module would upgrade the old git
test_auto_update_without_any_checkout_is_refused_before_a_git_upgrade() {
    lc_begin && gu_old_git "$AU_GIT_TOO_OLD_FOR_EARLY_CHECKS" && lc_make_fixtures && lc_use_fixtures && gu_module_env || return 1
    gu_tree_with_module testmod other <<<"$GU_MODULE_OK" || return 1
    gsg_tree install --auto-update --upgrade-git
    assert_rc 1 "no recorded checkout, this copy is not one, and the git is too old to read the state early"
    assert_contains "$ERR" "--auto-update needs a git checkout" "says what is missing"
    assert_contains "$ERR" "nothing was changed" "with the claim"
    assert_no_file "$SANDBOX/testmod.log" "the git upgrade was not applied before the refusal"
    assert_not_contains "$OUT" "testmod plan" "and not even offered"
    assert_nothing_installed "no checkout, old git"
}

# ^ invariant puts first on PATH a timeout that cuts every "--foreground -k GRACE LIMIT" call to one second and passes every other call on unchanged
# ^ coupled install finds this file with type -P and bounds its user-manager probe with it (lib/autoupdate/install_timer.sh)
# shellcheck disable=SC2016
au_short_timeout() {
    printf '#!/bin/sh\nif [ "$1" = --foreground ] && [ "$2" = -k ]; then shift 4; exec %s --foreground -k 1 1 "$@"; fi\nexec %s "$@"\n' \
        "$TEST_TIMEOUT" "$TEST_TIMEOUT" >"$SANDBOX/pathbin/timeout" || return 1
    chmod 755 "$SANDBOX/pathbin/timeout"
}

# shellcheck disable=SC2016
test_a_user_manager_that_never_answers_is_refused_before_any_change() {
    au_begin && au_short_timeout || return 1
    printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s/systemctl.log"\nexec sleep %s\n' "$SANDBOX" "$AU_HANG_SECONDS" >"$SANDBOX/pathbin/systemctl" || return 1
    gsg_from co install --auto-update
    assert_rc 1 "systemctl --user never answers"
    assert_contains "$ERR" "systemd user manager" "says what cannot be reached"
    assert_contains "$ERR" "gave no answer within" "and that the probe ran out of time"
    assert_contains "$ERR" "nothing was changed" "with the claim"
    assert_eq "$(systemctl_log)" "$PROBE_CALL" "only the probe ran"
    assert_nothing_installed "a manager that hangs"
    assert_no_file "$(unit_dir)" "no unit directory"
}

# shellcheck disable=SC2016
test_the_update_interval_text_gives_its_seconds() {
    au_lib 'for t in 1h 20s 999999s 0s 1000000s 5m "" 1h5; do if timer_interval_seconds "$t"; then echo "[$t]=$REPLY"; else echo "[$t] refused"; fi; done'
    assert_eq "$OUT" $'[1h]=3600\n[20s]=20\n[999999s]=999999\n[0s] refused\n[1000000s] refused\n[5m] refused\n[] refused\n[1h5] refused' "one grammar: 1h, or 1 to 999999 seconds"
}

test_the_launchd_plist_text_fails_closed_on_an_interval_it_cannot_read() {
    au_lib 'GSG_SHARE=/s INSTALL_BASH_BIN=/b/bash INSTALL_UPDATE_INTERVAL=5m GSG_LAUNCHD_UPDATE_LABEL=l GSG_UPDATE_AGENT_PLIST=/p GSG_UPDATE_AGENT_LOG=/l; launchd_job_set update; launchd_plist_text /usr/bin >/dev/null; echo "rc=$?"'
    assert_contains "$OUT" "rc=1" "no plist text is made"
    assert_contains "$ERR" "update interval [5m] is not 1h or <n>s" "the interval is named"
}

# shellcheck disable=SC2016
test_the_update_service_path_holds_the_dirs_of_the_recorded_tools_and_the_doctor_service_does_not() {
    local want_user='Environment="PATH=/opt/git/bin:/home/u/.local/bin:/usr/local/bin:/usr/bin:/bin"'
    local want_std='Environment="PATH=/usr/bin:/usr/local/bin:/bin"'
    local want_doctor='Environment="PATH=/opt/git/bin:/usr/local/bin:/usr/bin:/bin"'
    au_lib 'GSG_SHARE=/s INSTALL_BASH_BIN="" INSTALL_JQ_BIN=/home/u/.local/bin/jq INSTALL_SETSID_BIN=/home/u/.local/bin/setsid INSTALL_TIMEOUT_BIN=/usr/bin/timeout
        timer_update_service_text /opt/git/bin | grep "^Environment=\"PATH="
        INSTALL_JQ_BIN=/usr/bin/jq INSTALL_SETSID_BIN=/usr/bin/setsid
        timer_update_service_text /usr/bin | grep "^Environment=\"PATH="
        INSTALL_JQ_BIN=/home/u/.local/bin/jq
        timer_service_text /opt/git/bin | grep "^Environment=\"PATH="'
    assert_eq "$OUT" "$want_user"$'\n'"$want_std"$'\n'"$want_doctor" "tools outside the standard directories reach the update PATH once, the usual case keeps its order, the doctor PATH is as it was"
}

# ^ invariant au_odd_tools makes $SANDBOX/odd/bin with links to the real jq, setsid and timeout and puts it first on the PATH of the next install
# ^ order after au_begin; lc_begin empties EXTRA_ENV
au_odd_tools() {
    local name src
    rm -rf -- "$SANDBOX/odd" && mkdir -p -- "$SANDBOX/odd/bin" || return 1
    for name in jq setsid timeout; do
        src="$(PATH="$SANDBOX/pathbin:$TEST_BASE_PATH" type -P "$name")" || return 1
        ln -s -- "$src" "$SANDBOX/odd/bin/$name" || return 1
    done
    set_env PATH="$SANDBOX/odd/bin:$SANDBOX/pathbin:$TEST_BASE_PATH"
}

# ^ why type -P under the unit PATH, not a whole update run; the child install of update finds jq, setsid and timeout that way (lib/install/install.sh:install_resolve_bins)
# ^ why the directory of the recorded tool is asserted too; the git dir comes first in the unit PATH, so a copy of the tool there may win over the recorded one
# shellcheck disable=SC2016
test_the_update_service_path_finds_the_recorded_tools_for_the_child_install() {
    local odd="$SANDBOX/odd/bin" name up doc bin
    au_begin && au_odd_tools || return 1
    gsg_from co install --auto-update --with-timer
    assert_rc 0 "install --auto-update --with-timer with the tools in a user directory"
    up="$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$(unit_dir)/$UPD_SERVICE")"
    doc="$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$(unit_dir)/$SERVICE")"
    assert_contains ":$up:" ":$odd:" "the user directory is in the update service PATH"
    assert_not_contains ":$doc:" ":$odd:" "and not in the doctor service PATH"
    for name in jq setsid timeout; do
        bin="$(sed -n "s/^${name^^}_BIN=//p" "$LC_DATA/settings")"
        assert_contains ":$up:" ":${bin%/*}:" "the directory of the recorded $name is in the update service PATH"
        run_cap env -i PATH="$up" bash -c 'type -P "$1"' _ "$name"
        assert_file "$OUT" "$name is found under the unit PATH"
    done
}

# shellcheck disable=SC2016
test_an_update_service_with_the_old_path_is_rewritten_by_a_plain_install_with_the_reload_hint_only() {
    local odd="$SANDBOX/odd/bin" up old text
    au_begin && au_odd_tools || return 1
    gsg_from co install --auto-update
    assert_rc 0 "install --auto-update"
    text="$(<"$(unit_dir)/$UPD_SERVICE")"
    up="$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' <<<"$text")"
    run_cap env -i bash -c 'source "$1/lib/autoupdate/timer.sh" && timer_unit_path "$2"' _ "$GSG_PROJECT" "$(lc_first_git_dir)"
    old="$OUT"
    printf '%s\n' "${text/"$up"/"$old"}" >"$(unit_dir)/$UPD_SERVICE" || return 1
    au_reset_systemctl_log
    gsg_from co install
    assert_rc 0 "a plain install over a service with the old PATH"
    assert_contains "$OUT" "updated the auto-update timer units in $(unit_dir)" "the unit is rewritten and the user is told"
    assert_contains "$OUT" "systemctl --user daemon-reload" "with the reload hint"
    assert_contains "$(<"$(unit_dir)/$UPD_SERVICE")" "$odd" "the service holds the user directory again"
    assert_eq "$(systemctl_log)" "" "nothing is enabled or reloaded for the user"
}

test_the_linger_hint_gets_the_warning_icon_in_terminal_mode_only() {
    local hint="git-secret-guard: the updater runs only while you have a session; to keep it running after you log out, run: loginctl enable-linger"
    au_begin || return 1
    printf '#!/bin/sh\necho "$*" >>"%s/loginctl.log"\n' "$SANDBOX" >"$SANDBOX/pathbin/loginctl" && chmod 755 "$SANDBOX/pathbin/loginctl" || return 1
    gsg_from co install --auto-update
    assert_rc 0 "plain install --auto-update"
    assert_contains "$OUT" $'\n'"$hint" "the hint without an icon"
    ui_force_terminal
    gsg_from co install --auto-update
    assert_rc 0 "install --auto-update in terminal mode"
    assert_contains "$OUT" $'\n\e[33m▲\e[0m '"$hint" "the hint with the warning icon"
}

run_file_tests
