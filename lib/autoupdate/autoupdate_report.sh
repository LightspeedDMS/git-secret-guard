# shellcheck shell=bash disable=SC2153,SC2034
# ^ coupled status and doctor report the updater (#130); loaded by bin/git-secret-guard after lib/autoupdate/autoupdate.sh, never by the hook
# ^ invariant the state, the update record, the unit files, plist, wrapper and linger file are read as data; no manager (systemctl, launchctl, schtasks) is run
# ^ invariant status lines are information only; doctor's findings follow the rules of docs/doctor.md, an empty source_checkout gives none

GSG_UPDATE_RECORD_MAX_LINES=20
GSG_UPDATE_UNIT_MAX_LINES=100
GSG_UPDATE_TIME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
# ^ invariant the timer counts as inactive once its last check is older than 3 intervals plus one hour
GSG_UPDATE_STALE_INTERVALS=3
GSG_UPDATE_STALE_GRACE_HOURS=1
# ^ invariant the longest part of a bad checked_at value a doctor line repeats
GSG_UPDATE_SHOW_MAX=40
# ^ invariant the longest part of the recorded checkout path a status or doctor line shows, the cut marked by trunc_text
GSG_UPDATE_PATH_SHOW_MAX=200
GSG_UPDATE_LINGER_DIR=/var/lib/systemd/linger

# ^ invariant sets AR_CO_SHOW = the recorded checkout as printed, control characters replaced and cut at GSG_UPDATE_PATH_SHOW_MAX
# ^ why a copy for the text only, not for the checks; -d and <checkout>/VERSION need the path exactly as recorded
autoupdate_report_show() {
    trunc_text "${ST_SOURCE_CHECKOUT//[[:cntrl:]]/?}" "$GSG_UPDATE_PATH_SHOW_MAX"
    AR_CO_SHOW="$REPLY"
}

# ^ invariant sets AR_RECORD (1 = read), AR_CHECKED_AT, AR_RESULT, AR_LAST_TEXT ("<checked_at> <result> <reason>"), control characters replaced
# ^ invariant sets AR_STATUS_TEXT = AR_LAST_TEXT plus a colon and the detail, control characters replaced
# ^ invariant rc 1 = the record exists and cannot be read or is too long to be ours; a missing record is rc 0 with AR_RECORD=0
autoupdate_report_record() {
    local line val result="" reason="" detail=""
    local -a recs=()
    AR_RECORD=0 AR_CHECKED_AT="" AR_LAST_TEXT="" AR_RESULT="" AR_STATUS_TEXT=""
    if [ ! -e "$GSG_UPDATE_RECORD" ]; then return 0; fi
    { mapfile -t -n "$((GSG_UPDATE_RECORD_MAX_LINES + 1))" recs <"$GSG_UPDATE_RECORD"; } 2>/dev/null || return 1
    if [ "${#recs[@]}" -gt "$GSG_UPDATE_RECORD_MAX_LINES" ]; then return 1; fi
    for line in "${recs[@]}"; do
        val="${line#*=}"
        val="${val//[[:cntrl:]]/?}"
        case "$line" in
            checked_at=*) AR_CHECKED_AT="$val" ;;
            result=*) result="$val" ;;
            reason=*) reason="$val" ;;
            detail=*) detail="$val" ;;
        esac
    done
    AR_RECORD=1
    AR_RESULT="$result"
    # ^ why two texts, not one; doctor keeps AR_LAST_TEXT byte for byte and status adds the detail, naming each process and the lock it holds
    AR_LAST_TEXT="$AR_CHECKED_AT $result${reason:+ $reason}"
    AR_STATUS_TEXT="$AR_LAST_TEXT${detail:+: $detail}"
}

# ^ coupled lib/platform/launchd.sh:launchd_schedule prints this key line and the integer line after it, both are read back here
GSG_UPDATE_PLIST_KEY='    <key>StartInterval</key>'
GSG_UPDATE_PLIST_VALUE_RE='^[[:space:]]*<integer>([1-9][0-9]{0,5})</integer>$'

# ^ invariant sets AR_JOB_* for the update job; the platform is asked here, in the ownership test, the doctor link check and the linger check only
# ^ invariant AR_JOB_FILES = the files to be ours (service and timer unit, the plist, or the Windows wrapper), AR_JOB_FILE = the one with AR_JOB_KEY
# ^ invariant AR_JOB_SEE = where the output of a run is read; AR_JOB_READ = the reader of the schedule file; every file is read as data, no manager is run
autoupdate_report_job() {
    if brew_is_macos; then
        launchd_job_set update || return 1
        AR_JOB_FILE="$LJ_PLIST" AR_JOB_KEY=StartInterval AR_JOB_MARKER="$LJ_MARKER"
        AR_JOB_FILES=("$LJ_PLIST")
        AR_JOB_SEE="see: $LJ_LOG" AR_JOB_READ=autoupdate_report_plist_seconds
    elif tools_is_windows; then
        # ^ invariant Windows runs an hourly task nothing can change (#132); the wrapper with its marker is all the evidence, schtasks is never run
        AR_JOB_FILE="$GSG_UPDATE_TASK_CMD" AR_JOB_KEY=schedule AR_JOB_MARKER="$GSG_SCHTASKS_MARKER"
        AR_JOB_FILES=("$GSG_UPDATE_TASK_CMD")
        AR_JOB_SEE="see: $GSG_UPDATE_LOG" AR_JOB_READ=autoupdate_report_task_seconds
    else
        AR_JOB_FILE="$GSG_UNIT_DIR/$GSG_UPDATE_TIMER_UNIT" AR_JOB_KEY=OnUnitActiveSec AR_JOB_MARKER="$GSG_UPDATE_MARKER"
        AR_JOB_FILES=("$GSG_UNIT_DIR/$GSG_UPDATE_SERVICE_UNIT" "$GSG_UNIT_DIR/$GSG_UPDATE_TIMER_UNIT")
        AR_JOB_SEE="see: journalctl --user -u $GSG_UPDATE_SERVICE_UNIT" AR_JOB_READ=autoupdate_report_unit_seconds
    fi
}

# ^ invariant true only for a file this install wrote, judged by the marker of the job (autoupdate_report_job)
autoupdate_report_is_ours() {
    if brew_is_macos; then
        launchd_plist_is_ours "$1" "$AR_JOB_MARKER"
    elif tools_is_windows; then
        schtasks_cmd_is_ours
    else
        timer_unit_is_ours "$1" "$AR_JOB_MARKER"
    fi
}

# ^ invariant sets REPLY = the interval of the Windows task, fixed at one hour (#132); the wrapper being ours is the whole evidence
autoupdate_report_task_seconds() {
    REPLY="$GSG_UPDATE_INTERVAL_SECONDS"
}

# ^ invariant sets REPLY = the seconds of the OnUnitActiveSec line of the timer unit, 1h or <n>s; rc 1 = no such line in the first lines
autoupdate_report_unit_seconds() {
    local line n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$n" -gt "$GSG_UPDATE_UNIT_MAX_LINES" ]; then return 1; fi
        if [[ $line != "$AR_JOB_KEY"=* ]]; then continue; fi
        timer_interval_seconds "${line#"$AR_JOB_KEY"=}"
        return
    done <"$AR_JOB_FILE"
    return 1
}

# ^ invariant sets REPLY = the seconds of the StartInterval of the plist; the value is the line after the key line install writes
autoupdate_report_plist_seconds() {
    local line n=0 key=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$n" -gt "$GSG_UPDATE_UNIT_MAX_LINES" ]; then return 1; fi
        if [ "$key" -eq 1 ]; then
            if [[ ! $line =~ $GSG_UPDATE_PLIST_VALUE_RE ]]; then return 1; fi
            REPLY="${BASH_REMATCH[1]}"
            return 0
        fi
        if [ "$line" = "$GSG_UPDATE_PLIST_KEY" ]; then key=1; fi
    done <"$AR_JOB_FILE"
    return 1
}

# ^ invariant sets AR_INTERVAL = the interval as the status line shows it (1h, else <n>s) and AR_INTERVAL_SECONDS
# ^ invariant rc 1 = the schedule file is missing, not ours, or has no line install writes under AR_JOB_KEY
autoupdate_report_interval() {
    AR_INTERVAL="" AR_INTERVAL_SECONDS=""
    autoupdate_report_job || return 1
    autoupdate_report_is_ours "$AR_JOB_FILE" || return 1
    "$AR_JOB_READ" || return 1
    AR_INTERVAL_SECONDS="$REPLY" AR_INTERVAL="${REPLY}s"
    if [ "$REPLY" -eq "$GSG_UPDATE_INTERVAL_SECONDS" ]; then AR_INTERVAL="$GSG_UPDATE_INTERVAL"; fi
}

# ^ invariant none of these lines is a PROBLEM => the exit status of status never depends on them; WARNING asks the user to look, info and ok do not
autoupdate_status_lines() {
    local every level=ok last=info
    autoupdate_report_show
    if [ "$ST_AUTO_UPDATE" != yes ]; then
        status_line info "auto-update" "off"
        return 0
    fi
    if autoupdate_report_interval; then
        every="every $AR_INTERVAL"
    else
        every="interval unknown, $AR_JOB_FILE is missing or not ours"
        level=WARNING
    fi
    status_line "$level" "auto-update" "on (checkout ${AR_CO_SHOW:-none recorded}, $every)"
    if ! autoupdate_report_record; then
        status_line WARNING "last check" "the update record $GSG_UPDATE_RECORD cannot be read"
    elif [ "$AR_RECORD" -eq 1 ]; then
        if [ "$AR_RESULT" = failed ]; then last=WARNING; fi
        status_line "$last" "last check" "$AR_STATUS_TEXT"
    fi
}

# ^ invariant rc 0 = a PROBLEM was printed, the checkout's plain VERSION file is newer than the state's version or the installed VERSION
# ^ why the plain file, not git show HEAD:VERSION; a follower may not read the owner's git objects, it can read the file
# ^ coupled autoupdate_needs_install holds the version-gap rule and the strict x.y.z test; a version not x.y.z gives no finding
autoupdate_doctor_older() {
    local co="$1" want have rc=0
    autoupdate_first_line "$co/VERSION" || return 1
    want="$REPLY"
    if [ -z "$want" ]; then return 1; fi
    autoupdate_needs_install "$want" || rc=$?
    if [ "$rc" -ne 0 ]; then return 1; fi
    autoupdate_installed_version || return 1
    have="version $REPLY"
    # ^ why named, not replaced by the state's version; a share without VERSION is what needs the install (autoupdate_needs_install)
    if [ -z "$REPLY" ]; then have="copy (no VERSION file in $GSG_SHARE)"; fi
    doctor_machine_line PROBLEM "auto-update: the installed $have is older than $AR_CO_SHOW/VERSION ($want); install from the checkout: $AR_CO_SHOW/bin/git-secret-guard install"
}

# ^ invariant prints one timer-inactive PROBLEM with text $1 and always returns 1
autoupdate_inactive() {
    doctor_machine_line PROBLEM "auto-update: timer inactive: $1"
    return 1
}

# ^ invariant a WARNING only, never a PROBLEM; without linger the user manager and its timer stop when the user's last session ends
# ^ security the linger file is read as data, loginctl is never run; GSG_GITUP_ROOT moves /var into a sandbox for tests like the other system paths
# ^ invariant rc 1 = the system paths failed (doctor exits 2)
autoupdate_doctor_linger() {
    local user file
    if [ -z "${GITUP_SYSTEM_PATH:-}" ]; then gitup_paths || return 1; fi
    if ! user="$(id -un)"; then
        doctor_machine_line WARNING "auto-update: the user name cannot be read, linger was not checked"
        return 0
    fi
    file="$GITUP_ROOT$GSG_UPDATE_LINGER_DIR/$user"
    if [ -e "$file" ]; then return 0; fi
    doctor_machine_line WARNING "auto-update: linger is off for $user ($file is missing); the updater runs only while you have a session; to keep it running after you log out, run: loginctl enable-linger"
}

# ^ invariant rc 1 = a timer-inactive PROBLEM was printed; every job file must be ours and the schedule line readable, launchd's loaded state is never asked
# ^ invariant the one Linux-only check is the timers.target.wants link of systemctl enable; a LaunchAgent has no such link
# ^ invariant on rc 0 AR_INTERVAL and AR_INTERVAL_SECONDS are set (autoupdate_report_interval)
autoupdate_doctor_units() {
    local path fix="run: $AR_CO_SHOW/bin/git-secret-guard install --auto-update"
    local wants="$GSG_UNIT_DIR/timers.target.wants/$GSG_UPDATE_TIMER_UNIT"
    autoupdate_report_job || return 1
    for path in "${AR_JOB_FILES[@]}"; do
        if autoupdate_report_is_ours "$path"; then continue; fi
        if [ -e "$path" ] || [ -L "$path" ]; then autoupdate_inactive "$path was not written by git-secret-guard; move it away and $fix"; return; fi
        autoupdate_inactive "$path is missing; $fix"
        return
    done
    if ! brew_is_macos && ! tools_is_windows && [ ! -e "$wants" ]; then autoupdate_inactive "$wants is missing, the timer is not enabled; $fix"; return; fi
    autoupdate_report_interval || autoupdate_inactive "$AR_JOB_FILE has no $AR_JOB_KEY line install writes; $fix"
}

# ^ invariant rc 1 = a timer-inactive PROBLEM was printed; the last check, or the schedule file's mtime when no run is recorded, is older than the limit
# ^ why the schedule file's age (unit, plist or wrapper) without a record, not silence; a timer never started would otherwise stay invisible for ever
# ^ invariant on rc 0 AR_LAST says how the last check went, for the ok line; needs AR_INTERVAL_SECONDS
autoupdate_doctor_age() {
    local now at what limit see file name
    local span="$GSG_UPDATE_STALE_INTERVALS x $AR_INTERVAL + ${GSG_UPDATE_STALE_GRACE_HOURS}h"
    autoupdate_report_job || return 1
    file="$AR_JOB_FILE" name="${AR_JOB_FILE##*/}" see="$AR_JOB_SEE"
    limit=$((GSG_UPDATE_STALE_INTERVALS * AR_INTERVAL_SECONDS + GSG_UPDATE_STALE_GRACE_HOURS * 3600))
    AR_LAST=""
    now="$(date +%s)" || { autoupdate_inactive "the clock cannot be read, the age of the last check is unknown"; return; }
    autoupdate_report_record || { autoupdate_inactive "the update record $GSG_UPDATE_RECORD cannot be read; $see"; return; }
    if [ "$AR_RECORD" -eq 0 ]; then
        at="$(date -r "$file" +%s)" || { autoupdate_inactive "no update run is recorded, and the age of $name cannot be read; $see"; return; }
        what="no update run is recorded, and $name was written" AR_LAST="no update run is recorded yet"
    else
        # ^ security the strict form first; date -d accepts free text (next year), a record is data and never an expression
        if [[ ! $AR_CHECKED_AT =~ $GSG_UPDATE_TIME_RE ]] || ! at="$(date -u -d "$AR_CHECKED_AT" +%s 2>/dev/null)"; then
            autoupdate_inactive "checked_at [${AR_CHECKED_AT:0:$GSG_UPDATE_SHOW_MAX}] in $GSG_UPDATE_RECORD is not a UTC time; $see"
            return
        fi
        what="the last check was at $AR_CHECKED_AT," AR_LAST="last check $AR_LAST_TEXT"
    fi
    if [ "$((now - at))" -le "$limit" ]; then return 0; fi
    AR_LAST=""
    autoupdate_inactive "$what more than $span ago; $see"
}

# ^ invariant rc 1 = a timer-inactive PROBLEM was printed (at most one); the fix names AR_CO_SHOW (autoupdate_report_show)
autoupdate_doctor_timer() {
    autoupdate_doctor_units || return 1
    autoupdate_doctor_age
}

# ^ invariant the updater's doctor lines (docs/doctor.md); the older-install problem needs only a recorded, existing checkout
# ^ invariant the checkout-missing and timer-inactive problems and the linger warning need auto_update=yes; rc 1 = the system paths failed (doctor exit 2)
autoupdate_doctor_lines() {
    local co="$ST_SOURCE_CHECKOUT" bad=0
    if [ "$ST_EXISTS" -ne 1 ]; then return 0; fi
    autoupdate_report_show
    if [ "$ST_AUTO_UPDATE" != yes ]; then
        doctor_machine_line info "auto-update: off"
        if [ -n "$co" ] && [ -d "$co" ]; then autoupdate_doctor_older "$co" || true; fi
        return 0
    fi
    if [ -z "$co" ]; then return 0; fi
    if [ ! -d "$co" ]; then
        doctor_machine_line PROBLEM "auto-update: the recorded checkout $AR_CO_SHOW is missing; restore it, or run install --auto-update from the checkout to follow"
        bad=1
    elif autoupdate_doctor_older "$co"; then
        bad=1
    fi
    autoupdate_doctor_timer || bad=1
    # ^ invariant no linger line on macOS or Windows; the task runs during a logon session and install says so
    if ! brew_is_macos && ! tools_is_windows; then autoupdate_doctor_linger || return 1; fi
    if [ "$bad" -eq 0 ]; then doctor_machine_line ok "auto-update: on, following $AR_CO_SHOW every $AR_INTERVAL; $AR_LAST"; fi
}
