#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/autoupdate_units.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/autoupdate_units.sh"

# ^ external Windows has no systemd => install --auto-update is refused there, and no state can say auto_update=yes
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="systemd user units, Windows has no systemd"; fi

# ^ invariant a record written seconds ago; checked_at in the record format of lib/autoupdate/autoupdate.sh
AR_NOW=""
AR_USER=""
AR_LINGER=""

# ^ invariant ar_begin [FLAG...] = au_begin, the linger dir moved into the sandbox, one install from the checkout copy, a fresh record
# ^ external systemctl enable writes the timers.target.wants link, the stand-in does not => ar_begin makes it as systemd would
# ^ security loginctl is a recording stand-in => a test can prove doctor never runs it; the systemctl log is emptied after the install
ar_begin() {
    au_begin || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root"
    # ^ order after au_begin; lc_begin empties EXTRA_ENV
    if [ -n "${AR_TEST_INTERVAL:-}" ]; then set_env GSG_TEST_UPDATE_INTERVAL_SECONDS="$AR_TEST_INTERVAL"; fi
    AR_USER="$(id -un)" || return 1
    AR_LINGER="$SANDBOX/root/var/lib/systemd/linger"
    mkdir -p -- "$AR_LINGER" "$SANDBOX/roots" || return 1
    printf '#!/bin/sh\necho "$*" >>"%s/loginctl.log"\n' "$SANDBOX" >"$SANDBOX/pathbin/loginctl" && chmod 755 "$SANDBOX/pathbin/loginctl" || return 1
    gsg_from co install "$@"
    assert_rc 0 "install $*" || return 1
    if [ -f "$(unit_dir)/$UPD_TIMER" ]; then
        mkdir -p -- "$(unit_dir)/timers.target.wants" || return 1
        ln -s -- "$(unit_dir)/$UPD_TIMER" "$(unit_dir)/timers.target.wants/$UPD_TIMER" || return 1
    fi
    : >"$AR_LINGER/$AR_USER" || return 1
    au_reset_systemctl_log || return 1
    AR_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    ar_record "$AR_NOW" current ""
}

# ^ invariant ar_record CHECKED_AT RESULT REASON writes the update record in the seven-key format of autoupdate_record_write
ar_record() {
    printf 'checked_at=%s\nrole=owner\nresult=%s\nreason=%s\ndetail=\nfrom=%s\nto=\n' "$1" "$2" "$3" "$(<"$AU_CO/VERSION")" >"$LC_STATE/update"
}

# ^ invariant prints a UTC timestamp $1 seconds in the past, in the record format
ar_ago() { date -u -d "@$(($(date +%s) - $1))" +%Y-%m-%dT%H:%M:%SZ; }

# ^ invariant makes the checkout's plain VERSION file one minor version newer than the installed copy
ar_bump_checkout() {
    local v
    v="$(<"$AU_CO/VERSION")" || return 1
    IFS=. read -r AR_MAJ AR_MIN _ <<<"$v"
    AR_NEW="$AR_MAJ.$((AR_MIN + 1)).0"
    printf '%s\n' "$AR_NEW" >"$AU_CO/VERSION"
}

ar_doctor() { gsg doctor --roots "$SANDBOX/roots"; }

# ^ why a whole-line match, not assert_contains with newlines; the line may be the last one and $(...) drops the final newline
# ^ why the level column is stripped, not matched; status lines start with their tag and the tests name the text after it
ar_has_line() { sed -E 's/^  (PROBLEM|WARNING|ok|info) +//' <<<"$OUT" | grep -Fxq -- "$1" || fail "$2: no line [$1] in [${OUT:0:${GSG_TEST_DETAIL:-400}}]"; }

# ^ invariant the text of one doctor machine line, as doctor_machine_line prints it
ar_line() { printf '  %-8s %s' "$1" "$2"; }

ar_no_tool_calls() {
    assert_eq "$(systemctl_log)" "" "doctor and status never run systemctl"
    assert_no_file "$SANDBOX/loginctl.log" "doctor and status never run loginctl"
}

# ^ invariant asserts no PROBLEM or WARNING line about the updater; info and ok lines may be there
ar_no_updater_finding() {
    local line
    while IFS= read -r line; do
        case "$line" in
            "  PROBLEM  auto-update"* | "  WARNING  auto-update"*) fail "${1:-no updater finding}: [$line]" ;;
        esac
    done <<<"$OUT"
}

test_status_shows_auto_update_on_with_its_checkout_interval_and_last_check() {
    local base
    ar_begin --auto-update || return 1
    ar_record 2026-11-15T17:00:04Z skipped dirty
    au_reset_systemctl_log
    gsg status
    base="$RC"
    assert_contains "$OUT" "auto-update: on (checkout $AU_CO, every 1h)" "the on line names the checkout and the interval"
    ar_has_line "last check: 2026-11-15T17:00:04Z skipped dirty" "the last check line comes from the record"
    ar_record 2026-11-15T17:00:04Z current ""
    gsg status
    ar_has_line "last check: 2026-11-15T17:00:04Z current" "an empty reason leaves no trailing blank"
    ar_record 2000-01-01T00:00:00Z failed install-failed
    gsg status
    assert_eq "$RC" "$base" "a stale updater does not change the exit status of status"
    ar_bump_checkout || return 1
    gsg status
    assert_eq "$RC" "$base" "an install behind its checkout does not change the exit status of status"
    rm -f -- "$(unit_dir)/timers.target.wants/$UPD_TIMER" "$LC_STATE/update" || return 1
    gsg status
    assert_eq "$RC" "$base" "a missing wants link and no record do not change it either"
    assert_not_contains "$OUT" "last check:" "without a record there is no last check line"
    ar_no_tool_calls
}

test_status_shows_the_test_interval_the_units_carry() {
    local AR_TEST_INTERVAL=20
    ar_begin --auto-update || return 1
    gsg status
    assert_contains "$OUT" "auto-update: on (checkout $AU_CO, every 20s)" "the interval is read from the timer unit"
}

arm_plist() { printf '%s' "$LC_HOME/Library/LaunchAgents/com.lightspeeddms.git-secret-guard.update.plist"; }
arm_launchctl_log() { if [ -f "$SANDBOX/launchctl.log" ]; then cat -- "$SANDBOX/launchctl.log"; fi; }

# ^ external the launchd path runs on the Darwin flow; on Linux a fake uname says Darwin, the plist text is the same
# ^ invariant arm_begin [FLAG...] = a macOS sandbox with one install from the checkout copy, a fresh record, the launchctl log emptied
arm_begin() {
    lc_begin && as_macos && lc_make_fixtures && lc_use_fixtures && au_copy co git || return 1
    AU_CO="$(realpath -- "$SANDBOX/co")"
    set_env GSG_GITUP_ROOT="$SANDBOX/root"
    if [ -n "${AR_TEST_INTERVAL:-}" ]; then set_env GSG_TEST_UPDATE_INTERVAL_SECONDS="$AR_TEST_INTERVAL"; fi
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg_from co install "$@"
    assert_rc 0 "install $*" || return 1
    : >"$SANDBOX/launchctl.log" || return 1
    AR_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    ar_record "$AR_NOW" current ""
}

test_status_on_macos_reads_the_interval_from_the_update_plist() {
    local AR_TEST_INTERVAL=""
    arm_begin --auto-update || return 1
    ar_record 2026-11-15T17:00:04Z skipped dirty
    gsg status
    assert_contains "$OUT" "auto-update: on (checkout $AU_CO, every 1h)" "the plist says 3600 seconds"
    ar_has_line "last check: 2026-11-15T17:00:04Z skipped dirty" "the last check line comes from the record"
    printf '<!-- edited -->\n' >>"$(arm_plist)" || return 1
    gsg status
    assert_contains "$OUT" "every 1h" "an edited plist of ours still reads"
    printf 'not ours\n' >"$(arm_plist)" || return 1
    gsg status
    assert_contains "$OUT" "auto-update: on (checkout $AU_CO, interval unknown, $(arm_plist) is missing or not ours)" "a foreign plist is not read"
    rm -f -- "$(arm_plist)" || return 1
    gsg status
    assert_contains "$OUT" "interval unknown, $(arm_plist) is missing or not ours" "a missing plist too"
    assert_eq "$(arm_launchctl_log)" "" "status never runs launchctl"
    AR_TEST_INTERVAL=20
    arm_begin --auto-update || return 1
    gsg status
    assert_contains "$OUT" "auto-update: on (checkout $AU_CO, every 20s)" "the test interval, in the wording of the Linux units"
}

test_doctor_on_macos_is_green_reads_the_plist_and_gives_no_linger_warning() {
    local AR_TEST_INTERVAL=""
    arm_begin --auto-update || return 1
    ar_doctor
    assert_rc 0 "a healthy agent and a fresh record ($OUT)"
    assert_contains "$OUT" "$(ar_line ok "auto-update: on, following $AU_CO every 1h; last check $AR_NOW current")" "the ok line"
    assert_not_contains "$OUT" "linger" "a LaunchAgent has no linger"
    assert_eq "$(arm_launchctl_log)" "" "doctor reads the plist and never runs launchctl"
}

test_doctor_on_macos_reports_an_inactive_agent_from_the_plist_and_the_record_age() {
    local p fix
    arm_begin --auto-update || return 1
    p="$(arm_plist)"
    fix="run: $AU_CO/bin/git-secret-guard install --auto-update"
    cp -- "$p" "$SANDBOX/plist.keep" || return 1
    rm -f -- "$p" || return 1
    ar_doctor
    assert_rc 1 "no plist"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive: $p is missing; $fix")" "names the plist"
    printf 'not ours\n' >"$p" || return 1
    ar_doctor
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive: $p was not written by git-secret-guard; move it away and $fix")" "a foreign plist"
    { head -n 3 "$SANDBOX/plist.keep"; printf '<plist version="1.0">\n<dict>\n</dict>\n</plist>\n'; } >"$p" || return 1
    ar_doctor
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive: $p has no StartInterval line install writes; $fix")" "no interval to read"
    cp -- "$SANDBOX/plist.keep" "$p" || return 1
    ar_record "$(ar_ago $((4 * 3600 + 60)))" current ""
    ar_doctor
    assert_rc 1 "a record older than 3 x 1h + 1h"
    assert_contains "$OUT" "the last check was at" "names the age"
    assert_contains "$OUT" "see: $LC_STATE/update.log" "the hint names the update log, not the journal"
    assert_not_contains "$OUT" "journalctl" "no systemd hint"
    rm -f -- "$LC_STATE/update" || return 1
    touch -d '2000-01-01 00:00:00' "$p" || return 1
    ar_doctor
    assert_rc 1 "no record and an old plist"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive: no update run is recorded, and com.lightspeeddms.git-secret-guard.update.plist was written")" "the plist age stands in for the timer unit"
    assert_eq "$(arm_launchctl_log)" "" "doctor never runs launchctl"
}

test_status_shows_auto_update_off_for_a_plain_install() {
    ar_begin || return 1
    gsg status
    ar_has_line "auto-update: off" "the off line"
    assert_not_contains "$OUT" "last check:" "no last check line while auto-update is off"
}

test_doctor_reports_an_install_behind_its_checkout_with_auto_update_on() {
    ar_begin --auto-update || return 1
    ar_doctor
    assert_rc 0 "a current install behind nothing is clean ($OUT)"
    assert_contains "$OUT" "$(ar_line ok "auto-update: on, following $AU_CO every 1h; last check $AR_NOW current")" "the ok line"
    ar_bump_checkout || return 1
    ar_doctor
    assert_rc 1 "an install behind its checkout is a problem"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: the installed version $AR_MAJ.$AR_MIN")" "the problem names the installed version"
    assert_contains "$OUT" "is older than $AU_CO/VERSION ($AR_NEW)" "and the checkout's VERSION file"
}

test_doctor_reports_an_install_behind_its_checkout_with_auto_update_off() {
    ar_begin || return 1
    ar_doctor
    assert_rc 0 "a plain current install is clean ($OUT)"
    assert_contains "$OUT" "$(ar_line info "auto-update: off")" "doctor says auto-update is off"
    ar_bump_checkout || return 1
    ar_doctor
    assert_rc 1 "behind its checkout is a problem with auto-update off too"
    assert_contains "$OUT" "is older than $AU_CO/VERSION ($AR_NEW)" "the older-install problem"
    assert_contains "$OUT" "$(ar_line info "auto-update: off")" "and the off line"
}

test_doctor_uses_the_version_gap_rule() {
    ar_begin --auto-update || return 1
    ar_bump_checkout || return 1
    sed -i "s/^version=.*/version=$AR_NEW/" "$LC_STATE/state" || return 1
    ar_doctor
    assert_rc 1 "the state names the checkout's version, the copy is older"
    assert_contains "$OUT" "is older than $AU_CO/VERSION ($AR_NEW)" "the share's VERSION decides"
}

test_doctor_reads_the_plain_version_file_without_the_git_objects() {
    ar_begin --auto-update || return 1
    ar_bump_checkout || return 1
    chmod 000 "$AU_CO/.git" || return 1
    ar_doctor
    chmod 755 "$AU_CO/.git" || return 1
    assert_rc 1 "behind, read from the plain file"
    assert_contains "$OUT" "is older than $AU_CO/VERSION ($AR_NEW)" "a follower without access to .git still sees the gap"
}

test_a_version_that_is_not_x_y_z_gives_no_older_finding() {
    ar_begin --auto-update || return 1
    printf '9.9.9-rc1\n' >"$AU_CO/VERSION" || return 1
    ar_doctor
    assert_not_contains "$OUT" "is older than" "a non-numeric checkout version is never judged older"
}

test_an_empty_source_checkout_gives_no_updater_finding() {
    au_begin || return 1
    au_copy plain || return 1
    set_env GSG_GITUP_ROOT="$SANDBOX/root"
    mkdir -p -- "$SANDBOX/roots" || return 1
    gsg_from plain install
    assert_rc 0 "install from a copy that is no checkout"
    assert_eq "$(state_value source_checkout)" "" "no checkout is recorded"
    printf '99.0.0\n' >"$AU_CO/VERSION" || return 1
    ar_doctor
    assert_rc 0 "nothing to report ($OUT)"
    ar_no_updater_finding "an older state file"
    sed -i 's/^auto_update=.*/auto_update=yes/' "$LC_STATE/state" || return 1
    ar_doctor
    assert_rc 0 "auto_update=yes without a checkout reports nothing either ($OUT)"
    ar_no_updater_finding "auto_update=yes and no checkout"
}

test_doctor_reports_a_missing_checkout_only_with_auto_update_on() {
    ar_begin --auto-update || return 1
    mv -- "$AU_CO" "$SANDBOX/co.away" || return 1
    ar_doctor
    mv -- "$SANDBOX/co.away" "$AU_CO" || return 1
    assert_rc 1 "a missing checkout is a problem"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: the recorded checkout $AU_CO is missing")" "the problem names it"
    ar_begin || return 1
    mv -- "$AU_CO" "$SANDBOX/co.away" || return 1
    ar_doctor
    mv -- "$SANDBOX/co.away" "$AU_CO" || return 1
    assert_rc 0 "with auto-update off a missing checkout is no problem ($OUT)"
    ar_no_updater_finding "auto-update off, checkout missing"
}

test_doctor_reports_an_inactive_timer_from_files_and_the_record_age() {
    ar_begin --auto-update || return 1
    rm -f -- "$(unit_dir)/timers.target.wants/$UPD_TIMER" || return 1
    ar_doctor
    assert_rc 1 "no wants link"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive:")" "the timer-inactive problem"
    assert_contains "$OUT" "timers.target.wants/$UPD_TIMER" "it names the missing link"
    ln -s -- "$(unit_dir)/$UPD_TIMER" "$(unit_dir)/timers.target.wants/$UPD_TIMER" || return 1
    mv -- "$(unit_dir)/$UPD_SERVICE" "$SANDBOX/service.away" || return 1
    ar_doctor
    mv -- "$SANDBOX/service.away" "$(unit_dir)/$UPD_SERVICE" || return 1
    assert_rc 1 "a missing unit file"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive: $(unit_dir)/$UPD_SERVICE is missing")" "names the unit"
    ar_record "$(ar_ago $((4 * 3600 + 60)))" current ""
    ar_doctor
    assert_rc 1 "a record older than 3 x 1h + 1h"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive: the last check was at")" "names the age"
    ar_record "$(ar_ago $((2 * 3600)))" current ""
    ar_doctor
    assert_rc 0 "two hours is within 3 x 1h + 1h ($OUT)"
    ar_no_tool_calls
}

test_the_timer_threshold_follows_the_interval_in_the_units() {
    local AR_TEST_INTERVAL=20
    ar_begin --auto-update || return 1
    ar_record "$(ar_ago $((2 * 3600)))" current ""
    ar_doctor
    assert_rc 1 "two hours is past 3 x 20s + 1h"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive: the last check was at")" "stale under the test interval"
    ar_record "$(ar_ago 1800)" current ""
    ar_doctor
    assert_rc 0 "half an hour is within 3 x 20s + 1h ($OUT)"
}

test_a_missing_record_is_judged_by_the_age_of_the_timer_unit() {
    ar_begin --auto-update || return 1
    rm -f -- "$LC_STATE/update" || return 1
    ar_doctor
    assert_rc 0 "a timer written just now has not had to run yet ($OUT)"
    assert_contains "$OUT" "no update run is recorded yet" "the ok line says so"
    touch -d '2000-01-01 00:00:00' "$(unit_dir)/$UPD_TIMER" || return 1
    ar_doctor
    assert_rc 1 "a timer written long ago and no record"
    assert_contains "$OUT" "$(ar_line PROBLEM "auto-update: timer inactive: no update run is recorded")" "the problem"
}

test_doctor_reports_no_timer_problem_with_auto_update_off() {
    ar_begin || return 1
    rm -f -- "$LC_STATE/update" || return 1
    rm -f -- "$AR_LINGER/$AR_USER" || return 1
    ar_doctor
    assert_rc 0 "no units, no record, no linger and auto-update off ($OUT)"
    ar_no_updater_finding "auto-update off"
    assert_not_contains "$OUT" "linger" "no linger warning while auto-update is off"
}

test_doctor_warns_about_a_missing_linger_file_only_with_auto_update_on() {
    ar_begin --auto-update || return 1
    ar_doctor
    assert_not_contains "$OUT" "linger" "the linger file exists: no warning"
    rm -f -- "$AR_LINGER/$AR_USER" || return 1
    au_reset_systemctl_log
    ar_doctor
    assert_rc 0 "the linger warning alone does not make doctor exit 1 ($OUT)"
    assert_contains "$OUT" "$(ar_line WARNING "auto-update: linger is off for $AR_USER")" "the warning names the user"
    assert_contains "$OUT" "loginctl enable-linger" "and the command to run"
    ar_no_tool_calls
}

test_the_recheck_carries_the_updater_problem() {
    ar_begin --auto-update || return 1
    ar_bump_checkout || return 1
    ar_doctor
    assert_rc 1 "full run"
    gsg doctor --recheck
    assert_rc 1 "the recheck finds the problem again"
    assert_contains "$OUT" "is older than $AU_CO/VERSION ($AR_NEW)" "and prints it"
}

# ^ invariant a doctor run hanging on its input is killed after AR_DOCTOR_LIMIT seconds, KILL after the grace; timeout exits 124 or 137
AR_DOCTOR_LIMIT=60
AR_DOCTOR_KILL_GRACE=5
# ^ invariant 2 MiB, far past any bounded VERSION read
AR_BIG_VERSION_BYTES=2097152
# ^ coupled lib/autoupdate/autoupdate_report.sh:GSG_UPDATE_PATH_SHOW_MAX is the width shown before the cut mark; the long path is well past it
AR_PATH_CUT=200
AR_LONG_PATH_LEN=600

ar_doctor_bounded() {
    run_cap timeout -k "$AR_DOCTOR_KILL_GRACE" "$AR_DOCTOR_LIMIT" env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" doctor --roots "$SANDBOX/roots"
    if [ "$RC" -eq 124 ] || [ "$RC" -eq 137 ]; then fail "${1:-doctor}: doctor did not finish within $AR_DOCTOR_LIMIT seconds"; fi
}

# ^ invariant ar_filler CHAR COUNT prints COUNT copies of CHAR, no newline; rc 1 when COUNT is not a positive number
ar_filler() {
    if [[ ! $2 =~ ^[1-9][0-9]*$ ]]; then return 1; fi
    head -c "$2" /dev/zero | tr '\0' "$1"
}

test_a_fifo_as_the_checkout_version_does_not_hang_doctor() {
    ar_begin --auto-update || return 1
    rm -f -- "$AU_CO/VERSION" && mkfifo "$AU_CO/VERSION" || return 1
    ar_doctor_bounded "a FIFO as VERSION"
    assert_not_contains "$OUT" "is older than" "a FIFO is no version"
    ln -s -- /dev/zero "$SANDBOX/zero-link" && rm -f -- "$AU_CO/VERSION" && ln -s -- "$SANDBOX/zero-link" "$AU_CO/VERSION" || return 1
    ar_doctor_bounded "a link to a device as VERSION"
    assert_not_contains "$OUT" "is older than" "a device behind a link is no version"
}

test_an_oversized_checkout_version_line_is_read_bounded() {
    ar_begin --auto-update || return 1
    { printf '99.0.0' && ar_filler 9 "$AR_BIG_VERSION_BYTES" && printf '\n'; } >"$AU_CO/VERSION" || return 1
    ar_doctor_bounded "a 2 MiB VERSION line"
    assert_not_contains "$OUT" "is older than" "a line cut at the bound is not x.y.z"
    assert_not_contains "$OUT" "99.0.09999999999" "and it is never printed"
}

test_a_big_checkout_version_file_is_judged_by_its_first_line() {
    ar_begin --auto-update || return 1
    { printf '99.0.0\n' && ar_filler x "$AR_BIG_VERSION_BYTES"; } >"$AU_CO/VERSION" || return 1
    ar_doctor_bounded "a big VERSION file"
    assert_rc 1 "the first line is a newer version"
    assert_contains "$OUT" "is older than $AU_CO/VERSION (99.0.0)" "only the first line is read"
}

test_a_long_checkout_path_is_cut_in_status_and_doctor() {
    local long
    ar_begin --auto-update || return 1
    long="/$(ar_filler a "$AR_LONG_PATH_LEN")" || return 1
    sed -i "s|^source_checkout=.*|source_checkout=$long|" "$LC_STATE/state" || return 1
    gsg status
    assert_rc 0 "status succeeds with a long recorded path"
    assert_not_contains "$OUT" "$long" "status never prints the whole path"
    assert_contains "$OUT" "auto-update: on (checkout ${long:0:$AR_PATH_CUT}…, every 1h)" "it prints the start and marks the cut"
    ar_doctor
    assert_rc 1 "the long path names no checkout"
    assert_not_contains "$OUT" "$long" "doctor never prints the whole path"
    assert_contains "$OUT" "auto-update: the recorded checkout ${long:0:$AR_PATH_CUT}… is missing" "the missing-checkout problem is cut the same way"
}

test_status_last_check_shows_the_recorded_reason_and_detail_and_a_failed_check_is_a_warning() {
    local from
    ar_begin --auto-update || return 1
    from="$(<"$AU_CO/VERSION")" || return 1
    printf 'checked_at=2026-11-15T17:00:04Z\nrole=owner\nresult=skipped\nreason=locked\ndetail=process 4242 holds %s/update.lock\nfrom=%s\nto=\n' "$LC_STATE" "$from" >"$LC_STATE/update" || return 1
    gsg status
    assert_rc 0 "status"
    assert_contains "$OUT" "  info     last check: 2026-11-15T17:00:04Z skipped locked: process 4242 holds $LC_STATE/update.lock" "reason and detail, an info line"
    printf 'checked_at=2026-11-15T17:00:04Z\nrole=owner\nresult=failed\nreason=\ndetail=the install step exited 3\nfrom=%s\nto=\n' "$from" >"$LC_STATE/update" || return 1
    gsg status
    assert_rc 0 "a failed last check never changes the exit status"
    assert_contains "$OUT" "  WARNING  last check: 2026-11-15T17:00:04Z failed: the install step exited 3" "a warning line"
    assert_contains "$OUT" "summary: 0 problems, 1 warning" "counted in the summary"
    ar_doctor
    assert_not_contains "$OUT" "the install step exited 3" "doctor's text carries no detail"
    ar_record "$AR_NOW" current ""
}

run_file_tests
