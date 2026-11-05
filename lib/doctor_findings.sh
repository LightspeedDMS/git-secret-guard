# shellcheck shell=bash disable=SC2153,SC2034

# ^ invariant header lines (magic, time) precede one line per finding, machine TAB text or repo TAB path TAB worktree-or-dash TAB text
# ^ coupled GSG_FINDINGS_MAGIC lives in lib/common.sh; the hook reads line 1 of the record too
GSG_FINDINGS_TIME_RE='^time [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
GSG_FINDINGS_HEADER_LINES=2
GSG_FINDINGS_MAX_LINES=100000
GSG_FINDINGS_MAX_BYTES=67108864
GSG_FINDINGS_MACHINE_TABS=1
GSG_FINDINGS_REPO_TABS=3

DR_REC_OLD=()
DR_REC_TIME=""

# ^ invariant a recheck acts on the record and refuses it, the user repairs it with a full run; a full run says it is replacing it
doctor_rec_invalid() {
    if [ "${DR_RECHECK:-0}" -eq 1 ]; then
        printf '%s: the findings record %s is invalid (%s); run %s doctor to replace it\n' "$GSG_NAME" "$GSG_FINDINGS_FILE" "$1" "$GSG_NAME" >&2
    else
        printf '%s: the findings record %s is invalid (%s); replacing it\n' "$GSG_NAME" "$GSG_FINDINGS_FILE" "$1" >&2
    fi
    return 1
}

# ^ invariant rc 0 = $1 is not empty and holds no control character (a tab separates fields)
doctor_rec_text_ok() { [ -n "$1" ] && [[ $1 != *[[:cntrl:]]* ]]; }

# ^ invariant rc 0 = $1 is an absolute path without a control character
doctor_rec_path_ok() { doctor_rec_text_ok "$1" && [ "${1#/}" != "$1" ]; }

# ^ invariant rc 0 = $1 has the exact shape of a machine or a repo line; the text of a line is never printed, only its number
doctor_rec_line_ok() {
    local line="$1" rest path tree text without tabs
    without="${line//$'\t'/}"
    tabs=$((${#line} - ${#without}))
    case "$line" in
        machine$'\t'*)
            [ "$tabs" -eq "$GSG_FINDINGS_MACHINE_TABS" ] && doctor_rec_text_ok "${line#*$'\t'}"
            ;;
        repo$'\t'*)
            [ "$tabs" -eq "$GSG_FINDINGS_REPO_TABS" ] || return 1
            rest="${line#*$'\t'}"
            path="${rest%%$'\t'*}"
            rest="${rest#*$'\t'}"
            tree="${rest%%$'\t'*}"
            text="${rest#*$'\t'}"
            doctor_rec_path_ok "$path" && doctor_rec_text_ok "$text" && { [ "$tree" = - ] || doctor_rec_path_ok "$tree"; }
            ;;
        *) return 1 ;;
    esac
}

# ^ invariant sets DR_REC_OLD = the validated body lines; no file and a zero-byte file are an empty record; rc 1 = invalid, the reason is on stderr
# ^ why a regular non-symlink file only, not any path; the record is read as data from a user-owned dir, anything else was not written by doctor
doctor_rec_read() {
    local line n="$GSG_FINDINGS_HEADER_LINES" bytes
    local -a lines=() body=()
    DR_REC_OLD=() DR_REC_TIME=""
    if [ ! -e "$GSG_FINDINGS_FILE" ] && [ ! -L "$GSG_FINDINGS_FILE" ]; then return 0; fi
    if [ ! -f "$GSG_FINDINGS_FILE" ] || [ -L "$GSG_FINDINGS_FILE" ]; then
        doctor_rec_invalid "not a regular file"
        return
    fi
    bytes="$(wc -c <"$GSG_FINDINGS_FILE")" || {
        doctor_rec_invalid "cannot be read"
        return
    }
    if [ "$((bytes + 0))" -gt "$GSG_FINDINGS_MAX_BYTES" ]; then
        doctor_rec_invalid "more than $GSG_FINDINGS_MAX_BYTES bytes"
        return
    fi
    mapfile -t -n "$((GSG_FINDINGS_MAX_LINES + 1))" lines <"$GSG_FINDINGS_FILE" || {
        doctor_rec_invalid "cannot be read"
        return
    }
    if [ "${#lines[@]}" -eq 0 ]; then return 0; fi
    if [ "${#lines[@]}" -gt "$GSG_FINDINGS_MAX_LINES" ]; then
        doctor_rec_invalid "more than $GSG_FINDINGS_MAX_LINES lines"
        return
    fi
    if [ "${lines[0]}" != "$GSG_FINDINGS_MAGIC" ]; then
        doctor_rec_invalid "line 1 is not the header"
        return
    fi
    if [[ ! ${lines[1]:-} =~ $GSG_FINDINGS_TIME_RE ]]; then
        doctor_rec_invalid "line 2 is not the run time"
        return
    fi
    for line in "${lines[@]:$GSG_FINDINGS_HEADER_LINES}"; do
        n=$((n + 1))
        if ! doctor_rec_line_ok "$line"; then
            doctor_rec_invalid "line $n is malformed"
            return
        fi
        body+=("$line")
    done
    DR_REC_OLD=("${body[@]}")
    DR_REC_TIME="${lines[1]#time }"
}

GSG_FINDINGS_LOCK_ATTEMPTS=300
# ^ hazard 300 attempts outlast GSG_FINDINGS_LOCK_MAX_AGE_MIN on Windows (probed) => a live holder would be broken, never refused
# ^ why seconds, not fewer attempts; 40 attempts gave a queued run under load too little time (test_concurrent_runs_over_different_roots_keep_both_sets)
GSG_FINDINGS_LOCK_WAIT_SECONDS_WINDOWS=45
GSG_FINDINGS_LOCK_STEP=0.1
GSG_FINDINGS_LOCK_ABSENT_MAX=3
GSG_FINDINGS_LOCK_TEXT_MAX=40
DR_REC_LOCKED=0

# ^ invariant rc 0 = $1 is the pid of a live process of this user; anything else (also a pid reused by a foreign process) counts as a dead holder
doctor_rec_holder_alive() { [[ $1 =~ ^[0-9]+$ ]] && kill -0 "$1" 2>/dev/null; }

GSG_FINDINGS_LOCK_MAX_AGE_MIN=1

# ^ invariant rc 0 = the lock link itself is older than GSG_FINDINGS_LOCK_MAX_AGE_MIN minutes; the lock is held for milliseconds; an old one has no live owner
# ^ external find does not follow a symlink given as its start point by default (GNU and BSD), -prune keeps it from descending; -mmin is on both
doctor_rec_lock_old() {
    local found
    found="$(find "$GSG_FINDINGS_LOCK" -prune -mmin "+$GSG_FINDINGS_LOCK_MAX_AGE_MIN" 2>/dev/null)" || return 1
    [ -n "$found" ]
}

# ^ invariant $1 = what the lock is called in the message; rc 1 = it could not be removed
doctor_rec_remove_lock() {
    if ! rm -f -- "$GSG_FINDINGS_LOCK"; then
        printf '%s: cannot remove %s %s\n' "$GSG_NAME" "$1" "$GSG_FINDINGS_LOCK" >&2
        return 1
    fi
}

# ^ hazard a second run can remove a lock the first just made if both saw the same dead holder; the window is tiny and needs a crashed holder
# ^ invariant $1 = the dead holder's text; the lock is removed only if it still names the same holder
doctor_rec_break() {
    local now
    now="$(readlink -- "$GSG_FINDINGS_LOCK" 2>/dev/null)" || return 0
    if [ "$now" = "$1" ]; then doctor_rec_remove_lock "the stale lock"; fi
}

# ^ why a symlink named after the pid, not flock or mkdir plus a pid file; macOS ships no flock, and a symlink is created and given its owner in one atomic step
doctor_rec_try_lock() {
    # ^ external Git Bash ln -s refuses a missing target (probed) => winsymlinks:sys links without admin rights; other platforms ignore MSYS
    if MSYS=winsymlinks:sys ln -s "$$" "$GSG_FINDINGS_LOCK" 2>/dev/null; then
        DR_REC_LOCKED=1
        return 0
    fi
    return 1
}

# ^ invariant the lock is held for the read-merge-rename only, never during checks; the bound is a safety net, not a time limit on doctor
# ^ invariant no sleep follows the last look at the holder; a holder named in the refusal was seen alive just before, a dead one is broken and the lock retried
doctor_rec_lock() {
    local i holder="" absent=0 last=$((GSG_FINDINGS_LOCK_ATTEMPTS - 1)) stop_at=""
    if gsg_is_windows; then stop_at=$((SECONDS + GSG_FINDINGS_LOCK_WAIT_SECONDS_WINDOWS)); fi
    for ((i = 0; i < GSG_FINDINGS_LOCK_ATTEMPTS; i++)); do
        if [ -n "$stop_at" ] && [ "$SECONDS" -ge "$stop_at" ]; then break; fi
        if doctor_rec_try_lock; then return 0; fi
        holder="$(readlink -- "$GSG_FINDINGS_LOCK" 2>/dev/null)" || holder=""
        if [ -z "$holder" ]; then
            absent=$((absent + 1))
            if [ "$absent" -ge "$GSG_FINDINGS_LOCK_ABSENT_MAX" ]; then break; fi
            continue
        fi
        absent=0
        if doctor_rec_holder_alive "$holder" && ! doctor_rec_lock_old; then
            if [ "$i" -lt "$last" ]; then sleep "$GSG_FINDINGS_LOCK_STEP"; fi
        else
            doctor_rec_break "$holder" || return 1
            holder=""
            if doctor_rec_try_lock; then return 0; fi
        fi
    done
    if [ -z "$holder" ]; then
        printf '%s: cannot create the lock %s\n' "$GSG_NAME" "$GSG_FINDINGS_LOCK" >&2
        return 1
    fi
    trunc_text "$holder" "$GSG_FINDINGS_LOCK_TEXT_MAX"
    printf '%s: another run holds %s (process %s); gave up after %s attempts; if no doctor run is active, remove %s\n' "$GSG_NAME" "$GSG_FINDINGS_LOCK" "$REPLY" "$i" "$GSG_FINDINGS_LOCK" >&2
    return 1
}

# ^ invariant releases the lock only if it still names this process; a lock another run took over after a stale break is not ours to remove
doctor_rec_unlock() {
    if [ "$DR_REC_LOCKED" -ne 1 ]; then return 0; fi
    DR_REC_LOCKED=0
    if [ "$(readlink -- "$GSG_FINDINGS_LOCK" 2>/dev/null)" = "$$" ]; then doctor_rec_remove_lock "the lock"; fi
}

DR_REC_BODY=()
DR_REC_TMP=""
DR_REC_REPLACE_ROOTS=()
declare -gA DR_REC_REPLACE_REPOS=()
declare -gA DR_REC_GONE=()
declare -gA DR_REC_UNHELD=()

# ^ invariant rc 0 = old record line $1 is superseded by this run (machine lines, repo lines in DR_REC_REPLACE_REPOS or under DR_REC_REPLACE_ROOTS)
doctor_rec_replaced() {
    local rest path root
    if [[ $1 == machine$'\t'* ]]; then return 0; fi
    rest="${1#*$'\t'}"
    path="${rest%%$'\t'*}"
    if [[ -n ${DR_REC_REPLACE_REPOS[$path]:-} ]]; then return 0; fi
    for root in "${DR_REC_REPLACE_ROOTS[@]}"; do
        if { [ "$path" = "$root" ] || [[ $path == "${root%/}"/* ]]; } && [[ -n ${DR_REC_GONE[$path]:-} ]]; then return 0; fi
    done
    return 1
}

# ^ invariant rc 0 = no repository at $1 and every existing ancestor searchable; an unsearchable one or a relative path means unknown, never gone
# ^ why proof of absence, not absence from the discovery list; discovery stops at a depth, skips node_modules and cannot enter an unreadable directory
doctor_rec_proven_gone() {
    local dir="${1%/*}" parent
    if [ "${1#/}" = "$1" ]; then return 1; fi
    while [ -n "$dir" ]; do
        if [ -d "$dir" ] && [ ! -x "$dir" ]; then return 1; fi
        parent="${dir%/*}"
        if [ "$parent" = "$dir" ]; then break; fi
        dir="$parent"
    done
    ! doctor_rec_present "$1"
}

# ^ invariant rc 0 = temp file $1 is within the limits doctor_rec_read enforces; rc 1 = over one, the temp file is removed and the old record is never touched
# ^ invariant doctor never writes what it cannot read; the limits are the reader's constants, one shared definition
doctor_rec_check_size() {
    local lines bytes limit=""
    if ! lines="$(wc -l <"$1")" || ! bytes="$(wc -c <"$1")"; then
        printf '%s: cannot measure %s\n' "$GSG_NAME" "$1" >&2
        return 1
    fi
    if [ "$((lines + 0))" -gt "$GSG_FINDINGS_MAX_LINES" ]; then
        limit="$GSG_FINDINGS_MAX_LINES lines"
    elif [ "$((bytes + 0))" -gt "$GSG_FINDINGS_MAX_BYTES" ]; then
        limit="$GSG_FINDINGS_MAX_BYTES bytes"
    else
        return 0
    fi
    if rm -f -- "$1"; then
        DR_REC_TMP=""
    else
        printf '%s: cannot remove %s\n' "$GSG_NAME" "$1" >&2
    fi
    printf '%s: the findings record would exceed %s; the previous record is kept\n' "$GSG_NAME" "$limit" >&2
    return 1
}

doctor_rec_write_failed() {
    printf '%s: cannot write %s\n' "$GSG_NAME" "$1" >&2
    return 1
}

# ^ invariant the record is replaced by renaming a temp file made in the same directory => a reader sees the old file or the new one, never half of either
# ^ hazard mv onto a directory, or a symlink to one, moves the file into it and exits 0; a path resolving to a directory is refused first
# ^ invariant header and body are separate writes, each checked; a failed one leaves the temp file for doctor_cleanup and never reaches the rename
doctor_rec_write() {
    local now="${1:-}" tmp
    if [ -d "$GSG_FINDINGS_FILE" ]; then
        printf '%s: cannot write the findings record, %s is a directory\n' "$GSG_NAME" "$GSG_FINDINGS_FILE" >&2
        return 1
    fi
    # ^ coupled with tests/test_doctor_findings.sh:slow_date, a stand-in for this one date call; it must stay under the lock and after the old record was read
    if [ -z "$now" ]; then
        now="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
    fi
    tmp="$(umask 077 && mktemp "$GSG_STATE_DIR/findings.XXXXXX")" || {
        printf '%s: cannot create a temp file in %s\n' "$GSG_NAME" "$GSG_STATE_DIR" >&2
        return 1
    }
    DR_REC_TMP="$tmp"
    printf '%s\ntime %s\n' "$GSG_FINDINGS_MAGIC" "$now" >"$tmp" || doctor_rec_write_failed "$tmp" || return 1
    if [ "${#DR_REC_BODY[@]}" -gt 0 ]; then
        printf '%s\n' "${DR_REC_BODY[@]}" | LC_ALL=C sort -u >>"$tmp" || doctor_rec_write_failed "$tmp" || return 1
    fi
    doctor_rec_check_size "$tmp" || return 1
    mv -f -- "$tmp" "$GSG_FINDINGS_FILE" || {
        printf '%s: cannot replace %s\n' "$GSG_NAME" "$GSG_FINDINGS_FILE" >&2
        return 1
    }
    DR_REC_TMP=""
}

GSG_FINDINGS_TEMP_MAX_AGE_MIN=1
DR_REC_TIME_SEEN=""

# ^ invariant called under the lock; temp files are made and renamed under it, an old one belongs to a killed run
# ^ invariant a failed removal is said on stderr and the write goes on; the record matters more than the leftover
doctor_rec_clean_temps() {
    if ! find "$GSG_STATE_DIR" -maxdepth 1 -name 'findings.??????' -mmin "+$GSG_FINDINGS_TEMP_MAX_AGE_MIN" -exec rm -f -- {} +; then
        printf '%s: cannot remove old temp files in %s\n' "$GSG_NAME" "$GSG_STATE_DIR" >&2
    fi
    return 0
}

# ^ invariant $1 = 1 refuses an invalid record (recheck acts on it and needs it sound), 0 replaces it (a full run repairs it)
# ^ invariant the old record is read again under the lock; an update by a run finished meanwhile is merged, not overwritten
# ^ invariant a recheck writes back the time of the last full run, DR_REC_TIME_SEEN being the one it read first; a full run stamps the current time
doctor_rec_commit() {
    local strict="$1" line rc stamp=""
    DR_REC_BODY=()
    state_make_dir || return 1
    doctor_rec_lock || return 1
    doctor_rec_clean_temps
    if ! doctor_rec_read && [ "$strict" -eq 1 ]; then
        doctor_rec_unlock
        return 1
    fi
    if [ "$strict" -eq 1 ]; then stamp="${DR_REC_TIME:-$DR_REC_TIME_SEEN}"; fi
    for line in "${DR_REC_OLD[@]}"; do
        if ! doctor_rec_replaced "$line"; then DR_REC_BODY+=("$line"); fi
    done
    DR_REC_BODY+=("${DR_REC_NEW[@]}")
    doctor_rec_write "$stamp"
    rc=$?
    doctor_rec_unlock
    return "$rc"
}

# ^ why before the lock, not inside it; proven-gone stats every ancestor of a path and a slow mount would stretch the lock past its stale age
# ^ invariant an unlocked read names the recorded repos under the roots proven gone; a path appearing only under the lock is kept
# ^ invariant an unreadable or invalid record names nobody; the locked read after it reports the problem
doctor_rec_precompute_gone() {
    local line rest path root
    DR_REC_GONE=()
    doctor_rec_read 2>/dev/null || return 0
    for line in "${DR_REC_OLD[@]}"; do
        if [[ $line != repo$'\t'* ]]; then continue; fi
        rest="${line#*$'\t'}"
        path="${rest%%$'\t'*}"
        for root in "${DR_REC_REPLACE_ROOTS[@]}"; do
            if { [ "$path" = "$root" ] || [[ $path == "${root%/}"/* ]]; } && doctor_rec_proven_gone "$path"; then DR_REC_GONE[$path]=1; fi
        done
    done
}

# ^ invariant a full run replaces the machine records and those of every repository it saw and could record, and a record under its roots only when proven gone
doctor_rec_save_full() {
    local show
    DR_REC_REPLACE_ROOTS=("${DR_ROOT_LIST[@]}")
    DR_REC_REPLACE_REPOS=()
    for show in "${DR_SORTED[@]}"; do
        if [[ -z ${DR_REC_UNHELD[$show]:-} ]]; then DR_REC_REPLACE_REPOS[$show]=1; fi
    done
    doctor_rec_precompute_gone
    doctor_rec_commit 0
}

# ^ invariant all PROBLEMs of one repository are queued or none; a partial set would replace its old record with less than was found
# ^ invariant an unrecordable path is named on stderr and the repository stays out of the replaced set; one without a PROBLEM needs nothing
# ^ invariant $1 is never empty; it is a key of DR_KEY_OF, and the same key marks DR_REC_UNHELD here and is read back by doctor_rec_save_full
doctor_rec_collect() {
    local show="$1" i tree bad="" failed=0
    local -a lines=()
    for i in "${!DR_FIND[@]}"; do
        if [ "${DR_FIND[$i]%%$'\t'*}" != PROBLEM ]; then continue; fi
        tree="${DR_FIND_TREE[$i]}"
        if ! doctor_rec_path_ok "$show"; then
            failed=1 bad="$show"
            break
        fi
        if [ -n "$tree" ] && ! doctor_rec_path_ok "$tree"; then
            failed=1 bad="$tree"
            break
        fi
        lines+=("repo"$'\t'"$show"$'\t'"${tree:--}"$'\t'"${DR_FIND[$i]#*$'\t'}")
    done
    if [ "$failed" -eq 1 ]; then
        DR_REC_UNHELD[$show]=1
        printf '%s: not recorded: a path is not absolute or holds a control character: %s\n' "$GSG_NAME" "${bad//[[:cntrl:]]/?}" >&2
        return 0
    fi
    DR_REC_NEW+=("${lines[@]}")
}

# ^ invariant recheck prints open items only; keeps the PROBLEM entries of DR_FIND and DR_FIND_TREE, in step
doctor_keep_problems_only() {
    local i
    local -a keep=() keep_trees=()
    for i in "${!DR_FIND[@]}"; do
        if [ "${DR_FIND[$i]%%$'\t'*}" = PROBLEM ]; then
            keep+=("${DR_FIND[$i]}")
            keep_trees+=("${DR_FIND_TREE[$i]}")
        fi
    done
    DR_FIND=("${keep[@]}")
    DR_FIND_TREE=("${keep_trees[@]}")
}

DR_REC_REPOS=()
declare -gA DR_REC_TREES=()

# ^ invariant sets DR_REC_REPOS (recorded repository paths, once each, in record order) and DR_REC_TREES[path] (its recorded worktrees, one per line)
doctor_rec_recorded() {
    local line rest path tree
    local -A seen=()
    DR_REC_REPOS=()
    DR_REC_TREES=()
    for line in "${DR_REC_OLD[@]}"; do
        if [[ $line != repo$'\t'* ]]; then continue; fi
        rest="${line#*$'\t'}"
        path="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        tree="${rest%%$'\t'*}"
        if [[ -z ${seen[$path]:-} ]]; then
            seen[$path]=1
            DR_REC_REPOS+=("$path")
        fi
        if [ "$tree" != - ] && [[ $'\n'${DR_REC_TREES[$path]:-}$'\n' != *$'\n'"$tree"$'\n'* ]]; then
            DR_REC_TREES[$path]+="${DR_REC_TREES[$path]:+$'\n'}$tree"
        fi
    done
}

# ^ invariant rc 0 = $1 is a directory with a .git entry, file or directory; anything else is gone as far as the record is concerned
doctor_rec_present() { [ -d "$1" ] && { [ -e "$1/.git" ] || [ -L "$1/.git" ]; }; }

doctor_rec_gone() {
    printf '%s: %s no longer exists; dropped from the findings record\n' "$GSG_NAME" "${1//[[:cntrl:]]/?}" >&2
}

DR_REC_KEPT=()

# ^ invariant rc 0 = a repository is at $1, 1 = proven gone, 2 = unknown (an ancestor is not searchable); unknown never means gone
doctor_rec_state() {
    if doctor_rec_present "$1"; then return 0; fi
    if doctor_rec_proven_gone "$1"; then return 1; fi
    return 2
}

# ^ invariant keeps the recorded lines of repository $1 (or worktree $2 only) unchanged; queued for the new record, listed open, counted as PROBLEMs
# ^ order doctor_rec_print_machine ran before the repository phase; the queued kept lines are not printed twice
doctor_rec_keep() {
    local path="$1" tree="${2:-}" line rest p t label
    for line in "${DR_REC_OLD[@]}"; do
        if [[ $line != repo$'\t'* ]]; then continue; fi
        rest="${line#*$'\t'}"
        p="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        t="${rest%%$'\t'*}"
        if [ "$p" != "$path" ]; then continue; fi
        if [ -n "$tree" ] && [ "$t" != "$tree" ]; then continue; fi
        DR_REC_NEW+=("$line")
        DR_REC_KEPT+=("$line")
        DR_PROBLEMS=$((DR_PROBLEMS + 1))
    done
    label="${tree:-$path}"
    printf '%s: %s cannot be reached; kept in the findings record\n' "$GSG_NAME" "${label//[[:cntrl:]]/?}" >&2
}

# ^ invariant prints the kept lines in the shape of the repository phase, under the shared 'repos with findings:' header
doctor_rec_print_kept() {
    local line rest path text last=""
    if [ "${#DR_REC_KEPT[@]}" -eq 0 ]; then return 0; fi
    if [ "$DR_REPO_HEADER" -eq 0 ]; then
        printf 'repos with findings:\n'
        DR_REPO_HEADER=1
    fi
    for line in "${DR_REC_KEPT[@]}"; do
        rest="${line#*$'\t'}"
        path="${rest%%$'\t'*}"
        rest="${rest#*$'\t'}"
        text="${rest#*$'\t'}"
        if [ "$path" != "$last" ]; then
            printf '  %s\n' "${path//[[:cntrl:]]/?}"
            last="$path"
        fi
        printf '    %-8s %s\n' PROBLEM "$text"
    done
}

# ^ invariant at this point DR_REC_NEW holds only the machine lines of this run
doctor_rec_print_machine() {
    local line
    if [ "${#DR_REC_NEW[@]}" -eq 0 ]; then return 0; fi
    printf 'machine:\n'
    for line in "${DR_REC_NEW[@]}"; do
        printf '  %-8s %s\n' PROBLEM "${line#*$'\t'}"
    done
}

# ^ invariant no discovery; only recorded repositories and worktrees are looked at, each with the full per-repository checks
# ^ invariant every recorded repository is replaced in the record, also a gone one; no count or total-time limit, git calls keep DOCTOR_TIMEOUT_SECONDS
doctor_recheck_repos() {
    local path tree rc
    local -a trees=()
    doctor_bound_git || return 1
    doctor_discover_reset
    doctor_rec_recorded
    for path in "${DR_REC_REPOS[@]}"; do
        DR_REC_REPLACE_REPOS[$path]=1
        rc=0
        doctor_rec_state "$path" || rc=$?
        if [ "$rc" -eq 1 ]; then
            doctor_rec_gone "$path"
            continue
        fi
        if [ "$rc" -eq 2 ]; then
            doctor_rec_keep "$path"
            continue
        fi
        doctor_classify_dir "$path"
        if [[ -z ${DR_REC_TREES[$path]:-} ]]; then continue; fi
        mapfile -t trees <<<"${DR_REC_TREES[$path]}"
        for tree in "${trees[@]}"; do
            rc=0
            doctor_rec_state "$tree" || rc=$?
            case "$rc" in
                0) doctor_classify_dir "$tree" ;;
                1) doctor_rec_gone "$tree" ;;
                *) doctor_rec_keep "$path" "$tree" ;;
            esac
        done
    done
    doctor_finish_discovery
    doctor_rec_print_kept
    doctor_repo_loop
}

doctor_rec_save_recheck() {
    DR_REC_REPLACE_ROOTS=()
    doctor_rec_commit 1
}

# ^ invariant exit 0 = nothing remains (also no or empty record, nothing printed, no git run), 1 = a PROBLEM remains, 2 = could not run or invalid record
# ^ invariant stdout carries only open PROBLEMs (machine, repositories); notes about dropped repositories go to stderr, a caller can show stdout as is
# ^ invariant the record is validated before anything runs and doctor_start applies all its protections, as for a full run
doctor_recheck() {
    DR_RECHECK=1
    paths_init || return 2
    doctor_rec_read || return 2
    DR_REC_TIME_SEEN="$DR_REC_TIME"
    if [ "${#DR_REC_OLD[@]}" -eq 0 ]; then return 0; fi
    lifecycle_note_global_config
    doctor_require_git || return 2
    doctor_start || return 2
    DR_HOOK_CMD="$(hook_command_text "$GSG_SHARE" "$(share_recorded_bash "$GSG_SHARE")")" || return 2
    doctor_machine_checks || return 2
    doctor_rec_print_machine
    doctor_recheck_repos || return 2
    doctor_rec_save_recheck || return 2
    [ "$DR_PROBLEMS" -eq 0 ]
}
