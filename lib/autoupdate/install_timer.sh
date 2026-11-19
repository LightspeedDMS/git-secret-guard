# shellcheck shell=bash

# ^ invariant sets INSTALL_TIMER (1 = state records a timer), INSTALL_TIMER_ENABLE (1 = write and enable, --with-timer only), INSTALL_TIMER_BIN
# ^ invariant INSTALL_TIMER_BIN = systemctl, launchctl on macOS; a plain install over a recorded timer neither enables nor needs it, keeps the recorded path
install_prepare_timer() {
    local want="$1" found
    INSTALL_TIMER=0 INSTALL_TIMER_ENABLE=0 INSTALL_TIMER_BIN=""
    if [ "$want" -ne 1 ] && [ "$ST_TIMER" != yes ]; then return 0; fi
    if [ "$want" -ne 1 ]; then
        if install_find_timer_bin 2>/dev/null; then found="$REPLY"; else found=""; fi
        INSTALL_TIMER_BIN="${found:-$(install_recorded_timer_bin)}"
        INSTALL_TIMER=1
        return 0
    fi
    install_find_timer_bin || return 1
    INSTALL_TIMER_BIN="$REPLY"
    if brew_is_macos; then
        launchd_check_target "${GSG_GIT%/*}" || return 1
    else
        timer_check_target "${GSG_GIT%/*}" || return 1
    fi
    INSTALL_TIMER=1 INSTALL_TIMER_ENABLE=1
}

# ^ invariant prints LAUNCHCTL_BIN (macOS) or SYSTEMCTL_BIN from the settings file of the installed copy, "" when there is none
install_recorded_timer_bin() {
    (
        load_settings "$GSG_SHARE/settings" >/dev/null 2>&1 || exit 0
        if tools_is_windows; then
            printf '%s' "${SCHTASKS_BIN:-}"
        elif brew_is_macos; then
            printf '%s' "${LAUNCHCTL_BIN:-}"
        else
            printf '%s' "${SYSTEMCTL_BIN:-}"
        fi
    )
}

# ^ invariant $1 = doctor or update; sets TU_* (timer_unit_set) plus TU_SERVICE_TEXT and TU_TIMER_TEXT, the unit text for the git in use
# ^ coupled INSTALL_UPDATE_INTERVAL is set by install_update_interval before any update unit text is made
install_unit_texts() {
    timer_unit_set "$1" || return 1
    if [ "$1" = update ]; then
        TU_SERVICE_TEXT="$(timer_update_service_text "${GSG_GIT%/*}")" && TU_TIMER_TEXT="$(timer_update_timer_text "$INSTALL_UPDATE_INTERVAL")"
    else
        TU_SERVICE_TEXT="$(timer_service_text "${GSG_GIT%/*}")" && TU_TIMER_TEXT="$(timer_timer_text)"
    fi
}

# ^ invariant $1 = doctor or update, the unit pair to refresh
# ^ invariant rewrites a unit only when it is ours and its text changed; a foreign or missing unit is left alone, nothing is enabled and systemctl is not run
# ^ why only a hint for daemon-reload, not the call; a plain install must work where systemctl is gone or no user manager is reachable
install_refresh_units() {
    local unit path text changed=0
    local -a names=()
    install_unit_texts "$1" || return 1
    if [ "$1" = update ]; then names=("${GSG_UPDATE_ENV_NAMES[@]}" "${GSG_UPDATE_PATH_NAMES[@]}"); fi
    if ! timer_check_values "${GSG_GIT%/*}" "${names[@]}" 2>/dev/null; then
        printf '%s: the %s units were not refreshed: a path or variable cannot be written into a systemd unit; run install %s to see which\n' "$GSG_NAME" "$TU_SHORT" "$TU_FLAG" >&2
        return 0
    fi
    for unit in "$TU_SERVICE" "$TU_TIMER"; do
        path="$GSG_UNIT_DIR/$unit"
        if ! timer_unit_is_ours "$path" "$TU_MARKER"; then continue; fi
        if [ "$unit" = "$TU_SERVICE" ]; then text="$TU_SERVICE_TEXT"; else text="$TU_TIMER_TEXT"; fi
        if [ "$(<"$path")" = "$text" ]; then continue; fi
        timer_write_unit "$path" "$text" || {
            printf '%s: could not rewrite %s; the hook is installed and scanning\n' "$GSG_NAME" "$path" >&2
            return 1
        }
        changed=1
    done
    if [ "$changed" -eq 1 ]; then
        printf '%s: updated the %s units in %s; the timer is left as it was, run systemctl --user daemon-reload to make systemd read them\n' "$GSG_NAME" "$TU_LONG" "$GSG_UNIT_DIR"
    fi
}

# ^ order enable the timer after the hook config => a failing systemctl leaves the hook installed; state says timer_installed=yes before the units exist
install_enable_timer() {
    if [ "$INSTALL_TIMER" -ne 1 ]; then return 0; fi
    if brew_is_macos; then
        launchd_enable doctor "$INSTALL_TIMER_ENABLE"
        return
    fi
    if [ "$INSTALL_TIMER_ENABLE" -ne 1 ]; then
        install_refresh_units doctor
        return
    fi
    install_enable_units doctor
}

# ^ invariant $1 = doctor or update; writes the pair's two units and enables its timer with the systemctl found at install time (INSTALL_TIMER_BIN)
install_enable_units() {
    local rc
    install_unit_texts "$1" || return 1
    timer_write_units "$TU_SERVICE" "$TU_SERVICE_TEXT" "$TU_TIMER" "$TU_TIMER_TEXT" || {
        printf '%s: could not write the %s units into %s; the hook is installed and scanning\n' "$GSG_NAME" "$TU_SHORT" "$GSG_UNIT_DIR" >&2
        return 1
    }
    "$INSTALL_TIMER_BIN" --user enable --now "$TU_TIMER"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s: could not enable %s (systemctl exit %s); the hook is installed and scanning; fix the cause and run install %s again\n' \
            "$GSG_NAME" "$TU_TIMER" "$rc" "$TU_FLAG" >&2
        return 1
    fi
    printf '%s: %s enabled (%s); read its output with: journalctl --user -u %s\n' "$GSG_NAME" "$TU_LONG" "$GSG_UNIT_DIR/$TU_TIMER" "$TU_SERVICE"
}

# ^ invariant the longest text of the user's (a variable, a line systemctl printed) one refusal of this file repeats
INSTALL_UPDATE_TEXT_MAX=160

# ^ invariant sets INSTALL_UPDATE_INTERVAL = 1h, or <n>s from GSG_TEST_UPDATE_INTERVAL_SECONDS (tests only, for users the hour is fixed)
# ^ invariant $1 = 1 announces a set override on stderr, as tools_announce_overrides does; a value outside 1..999999 is refused, never guessed
install_update_interval() {
    local n="${GSG_TEST_UPDATE_INTERVAL_SECONDS:-}"
    INSTALL_UPDATE_INTERVAL="$GSG_UPDATE_INTERVAL"
    if [ -z "$n" ]; then return 0; fi
    # ^ external schtasks /SC HOURLY cannot express seconds => on Windows the knob is announced as ignored, and its value is never judged
    if tools_is_windows; then
        if [ "${1:-0}" -eq 1 ]; then
            printf '%s: GSG_TEST_UPDATE_INTERVAL_SECONDS is ignored on Windows; the update task runs every hour\n' "$GSG_NAME" >&2
        fi
        return 0
    fi
    if [[ ! $n =~ ^[1-9][0-9]{0,5}$ ]]; then
        trunc_text "${n//[[:cntrl:]]/?}" "$INSTALL_UPDATE_TEXT_MAX"
        printf '%s: GSG_TEST_UPDATE_INTERVAL_SECONDS must be a number of seconds from 1 to 999999 (got [%s]); %s\n' "$GSG_NAME" "$REPLY" "$(brew_unchanged_text)" >&2
        return 1
    fi
    INSTALL_UPDATE_INTERVAL="${n}s"
    if [ "${1:-0}" -eq 1 ]; then
        printf '%s: TEST OVERRIDE active (GSG_TEST_UPDATE_INTERVAL_SECONDS=[%s]); the update timer runs every %s seconds, not hourly\n' "$GSG_NAME" "$n" "$n" >&2
    fi
}

# ^ invariant sets REPLY = the absolute systemctl path; a missing or relative one prints the refusal of install_find_timer_bin, naming --auto-update
# ^ why two calls, not one; the first runs in a subshell to take the text, the second sets REPLY in this shell
install_update_find_bin() {
    local err
    if tools_is_windows; then
        schtasks_find
        return
    fi
    if err="$(install_find_timer_bin 2>&1 >/dev/null)"; then
        install_find_timer_bin
        return
    fi
    printf '%s\n' "${err//--with-timer/--auto-update}" >&2
    return 1
}

# ^ invariant the longest wait for the user manager's answer and the grace before KILL; a manager within reach answers in milliseconds
INSTALL_UPDATE_PROBE_SECONDS=30
INSTALL_UPDATE_PROBE_KILL_SECONDS=5
# ^ external GNU timeout exits 124 when the limit ended the command, 137 when it had to send KILL after the grace
INSTALL_UPDATE_RC_TIMEOUT=124
INSTALL_UPDATE_RC_KILLED=137

# ^ invariant $1 = systemctl; rc 0 = the user's systemd manager answered a read-only query; rc 1 = refused, with the first line systemctl printed
# ^ external without a session bus systemctl --user fails with "Failed to connect to user scope bus"; enabling the timer would fail the same way later
# ^ invariant the probe runs under the timeout install_check_prerequisites found (INSTALL_TIMEOUT_BIN); no answer within the limit = not reachable
install_update_manager_reachable() {
    local err rc why
    # ^ why --foreground, not a plain timeout; install runs at a terminal and Ctrl-C must reach systemctl, the probe starts no child of its own
    err="$("$INSTALL_TIMEOUT_BIN" --foreground -k "$INSTALL_UPDATE_PROBE_KILL_SECONDS" "$INSTALL_UPDATE_PROBE_SECONDS" "$1" --user show --property=Version 2>&1 >/dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ]; then return 0; fi
    if [ "$rc" -eq "$INSTALL_UPDATE_RC_TIMEOUT" ] || [ "$rc" -eq "$INSTALL_UPDATE_RC_KILLED" ]; then
        why="systemctl --user gave no answer within $INSTALL_UPDATE_PROBE_SECONDS seconds"
    else
        err="${err%%$'\n'*}"
        trunc_text "${err//[[:cntrl:]]/?}" "$INSTALL_UPDATE_TEXT_MAX"
        why="systemctl --user exit $rc: $REPLY"
    fi
    printf '%s: --auto-update needs your systemd user manager, and it cannot be reached (%s); log in with a full session, or have loginctl enable-linger run for your user, then run install --auto-update again; %s\n' \
        "$GSG_NAME" "$why" "$(brew_unchanged_text)" >&2
    return 1
}

# ^ invariant $1 = the directory of the git the job would name, $2 = the schtasks path; refuses a foreign file at a job path (plist, wrapper, systemd units)
install_update_check_target() {
    if brew_is_macos; then
        launchd_check_target "$1" update
    elif tools_is_windows; then
        schtasks_check_target "$2"
    else
        timer_check_target "$1" "$GSG_UPDATE_MARKER" "$GSG_UPDATE_SERVICE_UNIT" "$GSG_UPDATE_TIMER_UNIT"
    fi
}

# ^ order every --auto-update refusal needing neither the state nor the final git, before the git offers and before any lasting change
# ^ invariant $1 = the directory of the git the job would name; the systemd manager is asked last, once every check without a process has passed
install_update_precheck() {
    local bin
    # ^ external Windows has no systemd, its updater is an hourly Task Scheduler task (lib/platform/schtasks.sh) and the checks need one read-only query
    if tools_is_windows; then
        schtasks_find || return 1
        bin="$REPLY"
        install_update_interval || return 1
        install_update_check_target "$1" "$bin"
        return
    fi
    if ! brew_is_macos; then wsl_check_timer 1 --auto-update || return 1; fi
    install_update_find_bin || return 1
    bin="$REPLY"
    install_update_interval || return 1
    install_update_check_target "$1" "$bin" || return 1
    if brew_is_macos; then return 0; fi
    install_update_manager_reachable "$bin"
}

# ^ invariant always returns 1; the updater follows a git checkout, and neither the state nor this copy of the installer names one
install_update_no_checkout() {
    printf '%s: --auto-update needs a git checkout of git-secret-guard to follow: none is recorded and %s is not one; run install --auto-update from the checkout; %s\n' \
        "$GSG_NAME" "$GSG_ROOT" "$(brew_unchanged_text)" >&2
    return 1
}

# ^ why only with a state dir, not always; the lock lives there, and with no state dir no update run of this user can exist to collide with
# ^ coupled lib/autoupdate/autoupdate.sh owns the lock; install_cleanup of lib/install/install_tools.sh stays first in the trap, it reads the exit status
# ^ invariant the lock is released on every exit of install, also a refusal or a signal; the child install of an update run is let in by the lock
install_update_lock() {
    if [ ! -d "$GSG_STATE_DIR" ]; then return 0; fi
    # ^ invariant autoupdate_lock_take names the cause on stderr (a live run, a directory in the way, no lock made); install stops
    if ! autoupdate_lock_take; then
        printf '%s: install did not get the update lock %s and stops here; run install again once no other run is active; %s\n' \
            "$GSG_NAME" "$GSG_UPDATE_LOCK" "$(brew_unchanged_text)" >&2
        return 1
    fi
    trap 'install_cleanup; autoupdate_lock_release' EXIT
}

# ^ invariant sets INSTALL_AUTO_UPDATE (yes|no, for the state), INSTALL_UPDATE_ENABLE (1 = write and enable), INSTALL_SOURCE_CHECKOUT and INSTALL_UPDATE_FOLLOWS
# ^ order $1 = pre runs before the git offers; the call without it repeats the unit check with the final git directory and takes the update lock
# ^ coupled AUTO_UPDATE_FLAG comes from cmd_install (1 = --auto-update); ST_EXISTS is unset in the pre call when no usable git let install_run read the state
install_prepare_update() {
    local want="${AUTO_UPDATE_FLAG:-0}" dir=/usr/local/bin
    if [ "${1:-}" = pre ] && [ "$want" -ne 1 ]; then return 0; fi
    if [ -n "$GSG_GIT" ]; then dir="${GSG_GIT%/*}"; fi
    if [ "${1:-}" = pre ]; then
        install_update_precheck "$dir" || return 1
        # ^ order a state still unread is read here, state_read needs no git => the no-checkout refusal comes before the git offers
        if [ -z "${ST_EXISTS:-}" ]; then state_read || return 1; fi
        if [ ! -e "$GSG_ROOT/.git" ] && [ -z "$ST_SOURCE_CHECKOUT" ]; then install_update_no_checkout || return 1; fi
        return 0
    fi
    INSTALL_AUTO_UPDATE="$ST_AUTO_UPDATE" INSTALL_UPDATE_ENABLE=0 INSTALL_UPDATE_FOLLOWS=0 INSTALL_SOURCE_CHECKOUT="$ST_SOURCE_CHECKOUT"
    # ^ invariant every install run from a checkout records it; one run from the share dir or a tag export keeps the recorded checkout
    if [ -e "$GSG_ROOT/.git" ]; then INSTALL_SOURCE_CHECKOUT="$(realpath -- "$GSG_ROOT")" || return 1; fi
    if [ "$want" -eq 1 ]; then
        if [ -z "$INSTALL_SOURCE_CHECKOUT" ]; then install_update_no_checkout || return 1; fi
        install_update_find_bin || return 1
        INSTALL_TIMER_BIN="$REPLY"
        install_update_check_target "$dir" "$INSTALL_TIMER_BIN" || return 1
        INSTALL_AUTO_UPDATE=yes INSTALL_UPDATE_ENABLE=1
    elif [ "$INSTALL_AUTO_UPDATE" = yes ] && [ -z "$INSTALL_TIMER_BIN" ]; then
        # ^ invariant a plain install over a recorded auto-update needs no systemctl or schtasks; the recorded path stays in the settings for uninstall
        if install_update_find_bin 2>/dev/null; then INSTALL_TIMER_BIN="$REPLY"; else INSTALL_TIMER_BIN="$(install_recorded_timer_bin)"; fi
    fi
    if [ "$INSTALL_AUTO_UPDATE" = yes ]; then
        install_update_interval 1 || return 1
        if [ "$INSTALL_SOURCE_CHECKOUT" != "$ST_SOURCE_CHECKOUT" ]; then INSTALL_UPDATE_FOLLOWS=1; fi
    fi
    install_update_lock
}

# ^ order after the hook config => a failing systemctl leaves the hook installed; the state says auto_update=yes before the units exist
# ^ invariant linger is only named, never enabled; without it the updater runs only during a session of the user
install_enable_update() {
    if [ "$INSTALL_AUTO_UPDATE" != yes ]; then return 0; fi
    if [ "$INSTALL_UPDATE_FOLLOWS" -eq 1 ]; then printf '%s: auto-update now follows %s\n' "$GSG_NAME" "$INSTALL_SOURCE_CHECKOUT"; fi
    if tools_is_windows; then
        if [ "$INSTALL_UPDATE_ENABLE" -ne 1 ]; then schtasks_refresh; else schtasks_enable "$INSTALL_TIMER_BIN"; fi
        return
    fi
    if brew_is_macos; then
        launchd_enable update "$INSTALL_UPDATE_ENABLE"
        return
    fi
    if [ "$INSTALL_UPDATE_ENABLE" -ne 1 ]; then
        install_refresh_units update
        return
    fi
    install_enable_units update || return 1
    ui_prefix 1 WARNING
    printf '%s%s: the updater runs only while you have a session; to keep it running after you log out, run: loginctl enable-linger\n' "$REPLY" "$GSG_NAME"
}
