#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# ^ invariant the update log of macOS and Windows has stamped lines, a start line per run, earlier runs kept and one rotation; real git, real tags
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/autoupdate/autoupdate.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/autoupdate.sh"

# ^ coupled lib/autoupdate/autoupdate.sh stamps with the form of the record's checked_at, UTC with a Z
STAMP='[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z'

# ^ invariant ul_logged runs update the way launchd and the Windows wrapper do, both streams appended to the log, no terminal; RC = update's status
ul_logged_raw() {
    env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_DATA/bin/git-secret-guard" update </dev/null >>"$LC_STATE/update.log" 2>&1
    RC=$?
}

# ^ invariant ul_report prints what each way of telling the log sees with stdout and stderr appended to a probe file; the CI log shows the cause
# ^ external the bash -ef test stats the path /dev/stdout, stat on a duplicated descriptor asks the open file itself; macOS fdesc may differ between the two
ul_report() {
    local f="$SANDBOX/ul-probe.log"
    : >"$f" || return 1
    env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" bash -c "$AU_PRELUDE"'paths_init || exit 9; GSG_UPDATE_LOG="$1"
        autoupdate_log_target; trc=$?
        { [ /dev/stdout -ef "$GSG_UPDATE_LOG" ] && a=yes || a=no
          [ /dev/stderr -ef "$GSG_UPDATE_LOG" ] && b=yes || b=no
          o="$(stat -c "%d:%i" - <&3 2>&1)"; e="$(stat -c "%d:%i" - <&4 2>&1)"; p="$(stat -L -c "%d:%i" -- "$GSG_UPDATE_LOG" 2>&1)"
          echo "os=$(uname -s) bash=$BASH_VERSION stat=$(command -v stat) bash -ef stdout=$a stderr=$b; stat fd1=[$o] fd2=[$e] path=[$p]; autoupdate_log_target rc=$trc"
        } 3>&1 4>&2 >&9' _ "$GSG_PROJECT" "$f" >>"$SANDBOX/ul-probe.log" 2>&1 9>"$SANDBOX/ul-probe.report"
    cat -- "$SANDBOX/ul-probe.report"
}

# ^ invariant a logged run is only a test of stamping when update knows its streams are the log; if it does not, say what each method saw
ul_logged() {
    local rep
    ul_logged_raw
    rep="$(ul_report)" || rep="the probe could not run"
    case "$rep" in
        *"autoupdate_log_target rc=0"*) ;;
        *) fail "update does not recognise its streams as the log: $rep" ;;
    esac
}

# ^ invariant ul_stat_standin record|fail|same puts a stat first for update; record logs and runs the real one, fail exits 1, same logs and prints 1:1
# ^ external brew_use_gnubin puts GNUBIN_DIR of the settings ahead of PATH on macOS (tests/scan/test_lfs.sh) => the stand-in also goes into a gnubin copy
ul_stat_standin() {
    local real tool body
    real="$(command -v stat)" || return 1
    if [ -n "${TEST_GNUBIN:-}" ]; then real="$TEST_GNUBIN/stat"; fi
    case "$1" in
        record) body="$(printf '#!/bin/sh\nprintf "%%s\\n" "$*" >>"%s"\nexec "%s" "$@"\n' "$SANDBOX/ul-stat.log" "$real")" ;;
        fail) body="$(printf '#!/bin/sh\nexit 1\n')" ;;
        same) body="$(printf '#!/bin/sh\necho call >>"%s"\necho 1:1\n' "$SANDBOX/ul-stat.log")" ;;
        *) return 1 ;;
    esac
    printf '%s\n' "$body" >"$SANDBOX/pathbin/stat" || return 1
    chmod 755 "$SANDBOX/pathbin/stat" || return 1
    if [ -n "${TEST_GNUBIN:-}" ]; then
        rm -rf -- "${SANDBOX:?}/gnubin-stat" && mkdir -p -- "$SANDBOX/gnubin-stat" || return 1
        for tool in "$TEST_GNUBIN"/*; do ln -sf -- "$tool" "$SANDBOX/gnubin-stat/" || return 1; done
        rm -f -- "$SANDBOX/gnubin-stat/stat" && cp -- "$SANDBOX/pathbin/stat" "$SANDBOX/gnubin-stat/stat" || return 1
        printf 'GNUBIN_DIR=%q\n' "$SANDBOX/gnubin-stat" >>"$LC_DATA/settings" || return 1
    fi
    : >"$SANDBOX/ul-stat.log"
}

test_the_log_is_known_by_the_identity_of_the_open_descriptors() {
    local calls
    au_setup || return 1
    ul_stat_standin record || return 1
    # ^ why the raw run, not ul_logged; ul_report asks stat through the same stand-in, its calls would satisfy the assertions
    ul_logged_raw
    calls="$(<"$SANDBOX/ul-stat.log")"
    assert_rc 0 "a logged update"
    ul_all_stamped "$LC_STATE/update.log" || fail "the run is stamped"
    assert_eq "$(grep -c -x -F -- '-c %d:%i -' "$SANDBOX/ul-stat.log")" 2 "stat is asked once for each open descriptor, whole lines (the path call holds the same text)"
    assert_contains "$calls" "-L -c %d:%i -- $LC_STATE/update.log" "and for the identity of the log by its path"
}

# ^ hazard redirections run left to right => a closed stdout fails 3>&1 and bash reports it on stderr, possibly the log, unless 2>/dev/null comes first
test_a_closed_stdout_leaves_no_redirection_error_from_the_detection() {
    local line bad=0
    au_setup || return 1
    env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_DATA/bin/git-secret-guard" update </dev/null >&- 2>"$SANDBOX/ul-closed.err"
    RC=$?
    assert_rc 0 "the update with a closed stdout"
    while IFS= read -r line || [ -n "$line" ]; do
        if [[ $line =~ :\ line\ [0-9]+:\ [0-9]+:\ Bad\ file\ descriptor ]]; then bad=$((bad + 1)); fi
    done <"$SANDBOX/ul-closed.err"
    assert_eq "$bad" 0 "no redirection error of the detection reaches stderr: [$(head -c 400 "$SANDBOX/ul-closed.err" | tr '\n' '|')]"
}

# ^ invariant the logged path is entered once per run whatever the detection answers; the child carries a marker and never re-enters it
# ^ hazard a stat telling every descriptor is the log made the child start a child without end; the run is bounded here by a timeout as well
test_a_detection_that_is_always_true_still_logs_one_level_only() {
    local starts=0 line
    au_setup || return 1
    ul_stat_standin same || return 1
    env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$TEST_TIMEOUT" -k 5 40 "$LC_DATA/bin/git-secret-guard" update </dev/null >>"$LC_STATE/update.log" 2>&1
    RC=$?
    assert_rc 0 "the update ends, 124 would mean it never did"
    [ -s "$SANDBOX/ul-stat.log" ] || fail "the stat stand-in was never called, so the detection was not forced true"
    ul_load "$LC_STATE/update.log" || return 1
    for line in "${UL_LINES[@]}"; do
        if [[ $line == *"update: run started, "* ]]; then starts=$((starts + 1)); fi
    done
    assert_eq "$starts" 1 "one start line, one level"
    assert_contains "${UL_LINES[${#UL_LINES[@]} - 1]}" "update: current, 1.0.0 is installed" "and the result of the update"
}

test_the_logged_child_marker_does_not_reach_the_child_install() {
    au_setup || return 1
    # ^ why one variable, not an environment dump; a probe records only what it needs, a dump once printed real keys (CLAUDE.md)
    au_broken_installer "printf '%s\\n' \"\${GSG_UPDATE_LOGGED_CHILD-unset}\" >\"$SANDBOX/au-child.marker\"; exit 0" && au_release 1.1.0 && au_publish || return 1
    ul_logged
    assert_file "$SANDBOX/au-child.marker" "the stand-in installer ran and wrote the state of the marker"
    assert_eq "$(<"$SANDBOX/au-child.marker")" unset "the marker is gone before the install starts"
}

# ^ invariant any failure of the detection counts as not the log, the behaviour of a run without the stamping
test_a_stat_that_fails_means_not_the_log_and_the_run_stays_unstamped() {
    au_setup || return 1
    ul_stat_standin fail || return 1
    ul_logged_raw
    assert_rc 0 "the update runs"
    assert_eq "$(<"$LC_STATE/update.log")" "git-secret-guard: update: current, 1.0.0 is installed" "one plain line, no stamp, no start line"
}

# ^ invariant ul_load FILE sets UL_LINES to the lines of FILE; a last line without a newline counts
ul_load() {
    UL_LINES=()
    mapfile -t UL_LINES <"$1" || return 1
}

# ^ why -L as well as -e, not -e alone; the lock is a symlink to a pid and -e follows it
ul_assert_lock_released() {
    assert_no_file "$LC_STATE/update.lock" "$1"
    if [ -L "$LC_STATE/update.lock" ]; then fail "$1: a link to [$(readlink -- "$LC_STATE/update.lock")] is still there"; fi
}

# ^ invariant rc 0 = FILE is not empty and every line of it starts with a stamp and a space
ul_all_stamped() {
    local line
    ul_load "$1" && [ "${#UL_LINES[@]}" -gt 0 ] || return 1
    for line in "${UL_LINES[@]}"; do
        [[ $line =~ ^$STAMP\  ]] || { printf 'not stamped: [%s]\n' "$line" >&2; return 1; }
    done
}

test_a_logged_update_stamps_every_line_and_the_run_starts_with_the_installed_version() {
    au_setup || return 1
    ul_logged
    assert_rc 0 "a logged update with nothing newer"
    ul_all_stamped "$LC_STATE/update.log" || fail "every line of the log carries a stamp"
    assert_eq "${#UL_LINES[@]}" 2 "a start line and the result line, nothing else"
    [[ ${UL_LINES[0]} =~ ^$STAMP\ git-secret-guard:\ update:\ run\ started,\ 1\.0\.0\ is\ installed$ ]] || fail "the first line says the run started: [${UL_LINES[0]}]"
    [[ ${UL_LINES[1]} =~ ^$STAMP\ .*update:\ current,\ 1\.0\.0\ is\ installed$ ]] || fail "the last line is the result: [${UL_LINES[1]}]"
}

# ^ invariant the installed version is asserted, not only the exit status; the lock lets the child install in only when the logged child is a fresh bash
test_a_logged_update_that_installs_stamps_the_installer_output_and_ends_with_the_result() {
    au_setup_with_release || return 1
    ul_logged
    assert_rc 0 "a logged update that installs 1.1.0"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.1.0 "the child install was let in by the lock and installed"
    ul_all_stamped "$LC_STATE/update.log" || fail "every line of the log carries a stamp, the installer's too"
    [[ ${UL_LINES[0]} =~ ^$STAMP\ .*run\ started,\ 1\.0\.0\ is\ installed$ ]] || fail "the first line is the start line: [${UL_LINES[0]}]"
    [[ ${UL_LINES[${#UL_LINES[@]} - 1]} =~ ^$STAMP\ .*update:\ updated\ 1\.0\.0\ -\>\ 1\.1\.0$ ]] || fail "the last line is the result: [${UL_LINES[${#UL_LINES[@]} - 1]}]"
    [ "${#UL_LINES[@]}" -gt 2 ] || fail "the installer's own lines sit between the two, got ${#UL_LINES[@]} lines"
    ul_assert_lock_released "the lock is released"
}

test_a_second_logged_run_appends_and_the_first_run_stays() {
    local first
    au_setup || return 1
    ul_logged
    ul_load "$LC_STATE/update.log" && first="${UL_LINES[0]}" || return 1
    ul_logged
    assert_rc 0 "the second run"
    ul_all_stamped "$LC_STATE/update.log" || fail "every line is stamped"
    assert_eq "${#UL_LINES[@]}" 4 "two runs, two lines each"
    assert_eq "${UL_LINES[0]}" "$first" "the first run's start line is where it was"
    [[ ${UL_LINES[2]} =~ ^$STAMP\ .*run\ started ]] || fail "the second run starts with its own start line: [${UL_LINES[2]}]"
}

# ^ invariant a failed and a skipped run end with the status an unlogged run gives; the failure's stderr line is in the log, stamped
test_a_logged_run_keeps_the_exit_status_of_an_unlogged_one() {
    local want_rc want_err
    au_setup && au_broken_installer "echo \"git-secret-guard: $REFUSAL\" >&2; exit 1" && au_release 1.1.0 && au_publish || return 1
    upd
    want_rc="$RC" want_err="$ERR"
    assert_rc 1 "the unlogged run of a refusing installer fails"
    ul_logged
    assert_eq "$RC" "$want_rc" "the logged run fails with the same status"
    ul_all_stamped "$LC_STATE/update.log" || fail "every line is stamped"
    assert_contains "$(<"$LC_STATE/update.log")" "$REFUSAL" "the installer's stderr line reached the log"
    assert_contains "$want_err" "$REFUSAL" "and the unlogged run showed it on stderr"
    [[ ${UL_LINES[${#UL_LINES[@]} - 1]} =~ ^$STAMP\ .*update:\ failed ]] || fail "the last line is the failure: [${UL_LINES[${#UL_LINES[@]} - 1]}]"

    rm -f -- "$LC_STATE/update.log" || return 1
    au_state source_checkout "$SANDBOX/no-such-checkout" || return 1
    upd
    want_rc="$RC"
    assert_rc 0 "the unlogged run of a missing checkout is a skip"
    ul_logged
    assert_eq "$RC" "$want_rc" "the logged skip ends with the same status"
    ul_all_stamped "$LC_STATE/update.log" || fail "the skip is stamped"
}

# ^ invariant Linux logs to the journal, a pipe; a run to another file or to two files is the same, with no stamp and no start line
test_a_run_whose_output_is_not_the_update_log_is_unchanged() {
    local piped
    au_setup || return 1
    upd
    assert_rc 0 "the baseline run"
    assert_eq "$OUT" "git-secret-guard: update: current, 1.0.0 is installed" "plain, one line"
    piped="$(env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_DATA/bin/git-secret-guard" update </dev/null 2>&1 | cat; printf 'rc=%s' "${PIPESTATUS[0]}")" || return 1
    assert_eq "$piped" "$OUT"$'\n'"rc=0" "through a pipe: byte for byte the same, no stamp, no start line"
    env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_DATA/bin/git-secret-guard" update </dev/null >"$SANDBOX/ul.other" 2>&1
    assert_eq "$(<"$SANDBOX/ul.other")" "$OUT" "to a file that is not the update log: the same"
    env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_DATA/bin/git-secret-guard" update </dev/null >>"$LC_STATE/update.log" 2>"$SANDBOX/ul.err"
    assert_eq "$(<"$LC_STATE/update.log")" "$OUT" "only stdout in the update log, stderr elsewhere: not stamped"
}

# ^ invariant autoupdate_stamp reads to the end whatever the write does; the run feeding it is never cut by SIGPIPE
test_the_stamp_filter_drains_its_input_when_it_cannot_write() {
    lc_begin || return 1
    # ^ why a closed stdout, not /dev/full; macOS has no /dev/full, a write to a closed descriptor fails everywhere
    au_lib "$GSG_PROJECT" 'awk "BEGIN { for (i = 0; i < 50000; i++) print \"line\" }" | cat | autoupdate_stamp 1.0.0 >&-; echo "${PIPESTATUS[*]}"'
    assert_rc 0 "the body ran"
    assert_eq "$OUT" "0 0 0" "the writer and the filter all end 0: no SIGPIPE, no failed write ends the filter"
}

# ^ coupled lib/autoupdate/autoupdate.sh GSG_UPDATE_LOG_MAX is 1 MiB; ul_pad writes a log past it, its first line names the log
UL_LOG_MAX=1048576
ul_pad() {
    { printf '%s\n' "$2"; head -c "$UL_LOG_MAX" /dev/zero | tr '\0' x; printf '\n'; } >"$1"
}

test_a_log_over_the_bound_is_rotated_to_one_previous_file_and_a_smaller_one_is_appended_to() {
    local log before
    au_setup || return 1
    log="$LC_STATE/update.log"
    ul_pad "$log" 'first old log' || return 1
    ul_logged
    assert_rc 0 "a run over the bound"
    ul_load "$log.1" && assert_eq "${UL_LINES[0]}" "first old log" "the old content is in update.log.1"
    [ "$(wc -c <"$log.1")" -gt "$UL_LOG_MAX" ] || fail "the whole old log moved"
    ul_all_stamped "$log" || fail "the new log holds this run, stamped"
    assert_eq "${#UL_LINES[@]}" 2 "and nothing else"

    before="$(<"$log.1")"
    ul_logged
    assert_eq "$(wc -l <"$log" | tr -d ' ')" 4 "a log under the bound is appended to"
    assert_eq "$(<"$log.1")" "$before" "and update.log.1 stays as it was"

    ul_pad "$log" 'second old log' || return 1
    ul_logged
    ul_load "$log.1" && assert_eq "${UL_LINES[0]}" "second old log" "one previous file only: an older update.log.1 is replaced"
    ul_all_stamped "$log" || fail "the fresh log is stamped"
    assert_eq "${#UL_LINES[@]}" 2 "and holds one run"
}

# ^ hazard mv of a file onto a directory moves it inside and exits 0; the rotation refuses a directory at update.log.1 and says so
test_a_rotation_that_cannot_happen_is_said_and_the_run_goes_on() {
    local log
    au_setup || return 1
    log="$LC_STATE/update.log"
    ul_pad "$log" 'a long log' && mkdir -- "$log.1" || return 1
    ul_logged
    assert_rc 0 "the run is not changed by a failed rotation"
    assert_contains "$(<"$log")" "update: cannot move $log to $log.1" "the log says why it was not rotated"
    ul_load "$log" && assert_eq "${UL_LINES[0]}" "a long log" "the long log stays where it is"
    assert_eq "$(find "$log.1" -mindepth 1 | wc -l | tr -d ' ')" 0 "nothing was moved into the directory"
    assert_contains "$(<"$log")" "update: current, 1.0.0 is installed" "and the update ran"
}

# ^ external GNU timeout without --foreground moves into its own process group => a signal to the update's group does not reach the installer under it
# ^ invariant bash runs its trap when the step returns => the stand-in sleeps UL_INSTALLER_SLEEP seconds, and the run ends with the signal's code after
# ^ invariant UL_START_WAIT and UL_STOP_WAIT are only upper bounds of the polls; the signal goes out as soon as the stand-in has started
UL_INSTALLER_SLEEP=8 UL_START_WAIT=40 UL_STOP_WAIT=40

# ^ invariant ul_wait_until SECONDS CMD... polls CMD every tenth of a second; rc 1 = it still failed after SECONDS
ul_wait_until() {
    local i limit=$(($1 * 10))
    shift
    for ((i = 0; i < limit; i++)); do
        if "$@"; then return 0; fi
        sleep 0.1
    done
    return 1
}

# ^ why the state from ps, not kill -0; a child ended and not yet waited for is a zombie and still answers kill -0
ul_gone() {
    local state
    state="$(ps -o stat= -p "$1" 2>/dev/null)" || return 0
    state="${state//[[:space:]]/}"
    [ -z "$state" ] || [ "${state:0:1}" = Z ]
}

# ^ invariant ul_signal_case SIGNAL RC runs a logged update in its own process group, held in the child install, and sends SIGNAL to the group
# ^ why env --default-signal, not a plain env; a background job starts with SIGINT ignored, and a shell cannot trap a signal ignored at start
ul_signal_case() {
    local sig="$1" want="$2" pid rc=0 sbin
    au_setup && au_broken_installer "exec sleep $UL_INSTALLER_SLEEP" && au_release 1.1.0 && au_publish || return 1
    rm -f -- "$SANDBOX/au-child.args" || return 1
    # ^ why the setsid of the installed settings, not the one on PATH; the install recorded a usable one, a Mac test shell may have none on PATH
    sbin="$(bash -c 'source "$1" && printf "%s" "${SETSID_BIN:-}"' _ "$LC_DATA/settings")" || sbin=""
    sbin="${sbin:-${TEST_SETSID:-setsid}}"
    "$sbin" env --default-signal=INT,HUP,TERM env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$LC_DATA/bin/git-secret-guard" update </dev/null >>"$LC_STATE/update.log" 2>&1 &
    pid=$!
    ul_wait_until "$UL_START_WAIT" test -e "$SANDBOX/au-child.args" || {
        kill -KILL -- "-$pid" 2>/dev/null
        fail "the child install never started; setsid=[$sbin] executable=[$([ -x "$sbin" ] && echo yes || echo no)] env=[$(command -v env)] output of the update: [$(head -c 1500 "$LC_STATE/update.log" 2>&1 | tr '\n' '|')] $(ul_report)"
        return 1
    }
    kill "-$sig" -- "-$pid"
    if ! ul_wait_until "$UL_STOP_WAIT" ul_gone "$pid"; then
        fail "$sig did not end the logged update within $UL_STOP_WAIT s; left in its session: $(ps -o pid=,ppid=,stat=,args= -s "$pid" 2>&1 | cut -c1-110 | tr '\n' '|')"
        kill -KILL -- "-$pid" 2>/dev/null
        return 1
    fi
    wait "$pid" || rc=$?
    assert_eq "$rc" "$want" "$sig ends the logged update with the signal's code"
    ul_assert_lock_released "the lock is released"
    assert_eq "$(au_leftovers)" 0 "the work dir is removed"
    ul_all_stamped "$LC_STATE/update.log" || fail "every line of the log is stamped, the last ones included"
    [[ ${UL_LINES[0]} =~ ^$STAMP\ .*run\ started,\ 1\.0\.0\ is\ installed$ ]] || fail "the log starts with the start line: [${UL_LINES[0]}]"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.0.0 "nothing was installed"
    [[ ${UL_LINES[${#UL_LINES[@]} - 1]} =~ ^$STAMP\ git-secret-guard:\ update:\ stopped\ by\ $sig\ \(exit\ $want\)$ ]] || fail "the last line says who stopped the run: [${UL_LINES[${#UL_LINES[@]} - 1]}]"
    assert_not_contains "$(<"$LC_STATE/update.log")" "update: failed" "the run ended on the signal, not on the result of the install"
    assert_no_file "$LC_STATE/update" "and wrote no record"
}

test_a_logged_update_stopped_by_term_ends_cleanly_with_143() { ul_signal_case TERM 143; }
test_a_logged_update_stopped_by_int_ends_cleanly_with_130() { ul_signal_case INT 130; }
test_a_logged_update_stopped_by_hup_ends_cleanly_with_129() { ul_signal_case HUP 129; }

# ^ invariant the Windows wrapper text is built on any OS with a cygpath turning / into \ for -w; the real wrapper runs in test_autoupdate_schtasks
# ^ why one string for the libraries, not a copy per test; each test appends its own lines after the newline ending it
UL_WRAPPER_LIBS='source "$GSG_ROOT/lib/autoupdate/timer.sh" && source "$GSG_ROOT/lib/platform/schtasks.sh" && paths_init || exit 9
cygpath() { case "$1" in -w) printf "%s" "W:${2//\//\\}" ;; -m) printf "%s" "M:$2" ;; esac; }
'

test_the_wrapper_text_keeps_the_header_and_puts_everything_new_after_the_update_line() {
    local text log file="$SANDBOX/wrapper-text.cmd"
    lc_begin || return 1
    au_lib "$GSG_PROJECT" "$UL_WRAPPER_LIBS"'GSG_UPDATE_LOG="/state/50%/update.log"; schtasks_cmd_text "C:\bin\bash.exe" >"$1"; cat -- "$1"' "$file"
    assert_rc 0 "the wrapper text is made"
    text="${OUT//$'\r'/}"
    log='W:\state\50%%\update.log'
    assert_contains "$text" "if exist \"$log\" for %%F in (\"$log\") do if %%~zF GTR $UL_LOG_MAX move /y \"$log\" \"$log.1\" >nul 2>&1" "a rotation line, guarded by if exist, % doubled"
    assert_contains "$text" "\" update >> \"$log\" 2>&1" "update appends"
    assert_not_contains "$text" " update > " "and never truncates the log"
    [[ $text == *" update >> "*$'\n''set "GSG_RC=%errorlevel%"'$'\n'*"move /y"*$'\n''exit /b %GSG_RC%' ]] || fail "after the update line: the status is kept, the rotation follows, the exit returns the status"
    assert_not_contains "${text%% update >> *}" "move /y" "nothing new sits before the update line"
    # ^ why the bytes of a file, not a captured string; command substitution drops the end of the last line and Windows text handling alters CR
    assert_eq "$(tr -cd '\r' <"$file" | wc -c | tr -d ' ')" "$(wc -l <"$file" | tr -d ' ')" "every line of the wrapper ends in CRLF"
}

# ^ hazard cmd reopens the batch file by name and seeks to the byte offset it saved => a wrapper rewritten mid-run resumes inside the new text
# ^ invariant ul_old_head TEXT sets UL_OLD_HEAD = the v1.1.1 wrapper up to its update line (> for >>), built from the new text by the inverse change
ul_old_head() {
    UL_OLD_HEAD="${1%%set \"GSG_RC=*}"
    UL_OLD_HEAD="${UL_OLD_HEAD/ update >> / update > }"
}

test_an_old_wrapper_resumes_on_the_final_newline_of_the_new_update_line() {
    local want newhead lo old
    lc_begin || return 1
    # ^ invariant a literal copy of schtasks_cmd_text of v1.1.1 (git show v1.1.1:lib/platform/schtasks.sh), the wrapper the first update to this version runs
    cat >"$SANDBOX/v111.sh" <<'EOF'
schtasks_cmd_text_v111() {
    local n share log home
    share="$(cygpath -m "$GSG_SHARE")" || return 1
    log="$(cygpath -w "$GSG_UPDATE_LOG")" || return 1
    home="$(cygpath -w "$HOME")" || return 1
    printf '%s\r\n' '@echo off' "$GSG_SCHTASKS_MARKER" 'setlocal DisableDelayedExpansion'
    printf 'set "HOME=%s"\r\n' "${home//%/%%}"
    for n in "${GSG_TIMER_ENV_NAMES[@]}"; do
        if [ -n "${!n:-}" ]; then printf 'set "%s=%s"\r\n' "$n" "${!n//%/%%}"; fi
    done
    printf '"%s" "%s/bin/%s" update > "%s" 2>&1\r\n' "${1//%/%%}" "${share//%/%%}" "$GSG_NAME" "${log//%/%%}"
    printf 'exit /b %%errorlevel%%\r\n'
}
EOF
    au_lib "$GSG_PROJECT" "$UL_WRAPPER_LIBS"'source "$1"; schtasks_cmd_text "C:\bin\bash.exe"; printf "\036"; schtasks_cmd_text_v111 "C:\bin\bash.exe"' "$SANDBOX/v111.sh"
    assert_rc 0 "both wrapper texts are made"
    old="${OUT#*$'\036'}"
    OUT="${OUT%%$'\036'*}"
    ul_old_head "$OUT"
    assert_eq "$UL_OLD_HEAD" "${old%%exit /b *}" "the old text rebuilt from the new one is the v1.1.1 text up to its update line, byte for byte"
    newhead="${OUT%%set \"GSG_RC=*}"
    lo="${#UL_OLD_HEAD}"
    want='set "GSG_RC=%errorlevel%"'
    assert_eq "${#newhead}" "$((lo + 1))" "the new update line is exactly one byte longer than the old one"
    assert_eq "${UL_OLD_HEAD%% update > *}" "${newhead%% update >> *}" "every byte before the update's redirection is the old text"
    assert_eq "${OUT:$lo:1}" $'\n' "the offset cmd saved in the old file lands on the last byte of the new update line"
    assert_eq "${OUT:$((lo + 1)):${#want}}" "$want" "and the next command is the one that keeps the status"
}

# ^ invariant the child install of the update bringing this version refreshes a wrapper of ours whose text changed => an earlier install appends and rotates
test_a_refresh_rewrites_the_wrapper_an_earlier_version_wrote() {
    local old new
    lc_begin || return 1
    au_lib "$GSG_PROJECT" "$UL_WRAPPER_LIBS"'schtasks_bash && schtasks_cmd_text "$REPLY"'
    assert_rc 0 "the wrapper of the current version is made"
    ul_old_head "$OUT"
    { printf '%s' "$UL_OLD_HEAD"; printf 'exit /b %%errorlevel%%\r\n'; } >"$SANDBOX/old-wrapper.cmd" || return 1
    old="$(<"$SANDBOX/old-wrapper.cmd")"
    assert_contains "$old" " update > " "it truncates the log"
    au_lib "$GSG_PROJECT" "$UL_WRAPPER_LIBS"'state_make_dir && cp -- "$1" "$GSG_UPDATE_TASK_CMD" && schtasks_refresh && cat -- "$GSG_UPDATE_TASK_CMD"' "$SANDBOX/old-wrapper.cmd"
    assert_rc 0 "the refresh of a wrapper of ours"
    new="${OUT//$'\r'/}"
    assert_contains "$new" " update >> " "now appends"
    assert_contains "$new" "move /y" "and rotates"
}

run_file_tests
