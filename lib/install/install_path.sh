# shellcheck shell=bash disable=SC2034
# ^ why a file-wide SC2034 off, not one per line; every INSTALL_PATH_* global set here is read by install.sh, status.sh, doctor.sh and uninstall.sh

# ^ coupled the line a person adds by hand; the block install writes on macOS holds the same line (lib/platform/macpath.sh), $HOME stays literal
# shellcheck disable=SC2016
GSG_PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
# ^ coupled install_path_plan sets these; install_write_state records INSTALL_PATH_RECORD and install_path_report prints the rest
# ^ invariant INSTALL_PATH_RECORD is what the state holds (an earlier install's record or none) until install_path_apply moves INSTALL_PATH_NEWREC into it
INSTALL_PATH_ACTION="" INSTALL_PATH_WHY="" INSTALL_PATH_RECORD="" INSTALL_PATH_NEWREC=""

# ^ invariant sets REPLY = folder $1 as the comparison sees it, trailing slashes cut ("/" stays "/"); on Windows through cygpath -m -l and in lower case
# ^ invariant rc 1 (REPLY empty) for an empty folder or when cygpath cannot name it => no match, never a guess; cygpath's own message stays visible
install_path_norm() {
    local v="$1"
    REPLY=""
    if [ -z "$v" ]; then return 1; fi
    if tools_is_windows; then
        v="$(cygpath -m -l -- "$v")" || return 1
        v="${v,,}"
    fi
    install_path_trim "$v"
}

# ^ invariant sets REPLY = $1 with its trailing slashes cut, "/" for a value of slashes only
install_path_trim() {
    REPLY="${1%"${1##*[!/]}"}"
    if [ -z "$REPLY" ]; then REPLY=/; fi
}

# ^ invariant rc 0 = folder $1 is an entry of the PATH install runs with; one comparison for every platform, an empty entry never matches
# ^ external on Windows one cygpath -m -l -p call turns the whole PATH into ;-separated Windows paths; a failure is no match, never a guess
# ^ invariant the loop ends as rest loses its first entry at every turn; the list is walked by expansion, never fed through a here-string
install_path_has_dir() {
    local want entry rest sep=:
    install_path_norm "$1" || return 1
    want="$REPLY"
    rest="$PATH"
    if tools_is_windows; then
        # ^ why the empty entries are cut before cygpath, not after; it may turn one into "." or drop it, and an empty one never matches anyway
        # ^ invariant each pass shortens the list, the loop ends
        while [[ $rest == *::* ]]; do rest="${rest//::/:}"; done
        rest="${rest#:}" rest="${rest%:}"
        if [ -z "$rest" ]; then return 1; fi
        rest="$(cygpath -m -l -p -- "$rest")" || return 1
        rest="${rest,,}" sep=";"
    fi
    rest+="$sep"
    while [ -n "$rest" ]; do
        entry="${rest%%"$sep"*}"
        rest="${rest#*"$sep"}"
        if [ -z "$entry" ]; then continue; fi
        install_path_trim "$entry"
        if [ "$REPLY" = "$want" ]; then return 0; fi
    done
    return 1
}

# ^ invariant rc 0 = this process is the child install of an update run (AU_LET_IN, set by autoupdate_lock_take); the one place deciding it
# ^ security the variable GSG_UPDATE_LOCK_PID alone proves nothing (any environment can hold it) => only the lock code's verdict counts
install_path_is_update_child() { [ "${AU_LET_IN:-0}" -eq 1 ]; }

# ^ invariant read-only; sets INSTALL_PATH_ACTION (onpath | hint), INSTALL_PATH_WHY (why nothing is changed) and INSTALL_PATH_RECORD (what the state records)
# ^ invariant a record of ours from an earlier install is carried over unchanged, never dropped and never duplicated
# ^ why the default reason is generic, not per platform; Linux never edits a file, and the macOS and Windows branches set their own
install_path_plan() {
    INSTALL_PATH_ACTION=hint INSTALL_PATH_WHY="install changes no file on this platform" INSTALL_PATH_RECORD="${ST_CLI_PATH:-}" INSTALL_PATH_NEWREC=""
    if install_path_has_dir "$GSG_BIN_DIR"; then
        INSTALL_PATH_ACTION=onpath INSTALL_PATH_WHY=""
        return 0
    fi
    if [ "${INSTALL_PATH_FLAG:-0}" -eq 1 ]; then
        INSTALL_PATH_WHY="--dont-change-path was given"
        return 0
    fi
    if install_path_is_update_child; then
        INSTALL_PATH_WHY="the unattended install of update never changes PATH"
        return 0
    fi
    if tools_is_windows; then
        install_path_plan_windows
    elif brew_is_macos; then
        macpath_plan
    fi
}

# ^ invariant maps the answer of winpath_plan to the plan; absent = add with the adapter's record, present = nothing to do, else a hint
install_path_plan_windows() {
    local old=""
    winpath_plan "$GSG_BIN_DIR"
    case "$REPLY" in
        absent)
            INSTALL_PATH_ACTION=add INSTALL_PATH_WHY="" INSTALL_PATH_NEWREC="$WINPATH_RECORD"
            # ^ invariant one record slot; a record for another folder stays (uninstall removes it), the folders are compared without case
            # ^ invariant the recorded folder is asked about too; absent = the entry is gone, the add goes on; a failed question never drops a record
            if state_winrec_split "${ST_CLI_PATH:-}"; then
                old="$ST_WINREC_FOLDER"
                if state_winrec_split "$WINPATH_RECORD" && [ "${old,,}" != "${ST_WINREC_FOLDER,,}" ]; then
                    winpath_plan "$old"
                    if [ "$REPLY" != absent ]; then
                        INSTALL_PATH_ACTION=hint INSTALL_PATH_NEWREC=""
                        INSTALL_PATH_WHY="the state records an entry for another folder, $old, which $GSG_NAME uninstall removes; install left the user Path alone"
                    fi
                fi
            fi
            ;;
        present) INSTALL_PATH_ACTION=present INSTALL_PATH_WHY="the user Path already holds $GSG_BIN_DIR" ;;
        *) INSTALL_PATH_ACTION=hint INSTALL_PATH_WHY="$WINPATH_WHY" ;;
    esac
}

# ^ invariant a failed change is the action failed with its reason and the PATH step never fails install; the hook stays installed and status is as before
# ^ invariant rc 1 only when a state write fails, before the change (nothing is written) or in install_path_unrecord; a written change keeps its record
# ^ order runs after the hook config is set; the record goes into the state right before the change => recorded before made, nothing written = no record
install_path_apply() {
    INSTALL_PATH_DONE=""
    if [ "$INSTALL_PATH_ACTION" != add ]; then return 0; fi
    INSTALL_PATH_RECORD="$INSTALL_PATH_NEWREC"
    if ! install_write_state final; then
        INSTALL_PATH_RECORD="${ST_CLI_PATH:-}" INSTALL_PATH_ACTION=failed INSTALL_PATH_WHY="the state file could not record the change first"
        printf '%s: PATH: could not write the state file %s before the PATH change; nothing was written to PATH\n' "$GSG_NAME" "$GSG_STATE_FILE" >&2
        return 1
    fi
    if tools_is_windows; then
        if winpath_apply "$GSG_BIN_DIR"; then
            INSTALL_PATH_DONE="added $GSG_BIN_DIR to the user Path"
            if [ "${WINPATH_NOBROADCAST:-0}" -eq 1 ]; then INSTALL_PATH_DONE+="; could not tell running programs; sign out and in, or start a new session"; fi
        else
            INSTALL_PATH_ACTION=failed INSTALL_PATH_WHY="$WINPATH_WHY"
        fi
    elif macpath_apply; then
        INSTALL_PATH_DONE="added a marked block to $MACPATH_RFILE"
    else
        INSTALL_PATH_ACTION=failed INSTALL_PATH_WHY="$MACPATH_WHY"
    fi
    if [ "$INSTALL_PATH_ACTION" = failed ]; then install_path_unrecord; fi
}

# ^ invariant nothing was written => the state goes again without this run's record, an earlier install's stays; a stale record could cut a user's entry
# ^ why rc 1 reaches install's status, not a warning alone; every failed install_write_state does, and the PATH change itself never does
# ^ invariant rc 1 names the state file in one line on stderr and the record in it is stale
install_path_unrecord() {
    INSTALL_PATH_RECORD="${ST_CLI_PATH:-}"
    if install_write_state final; then return 0; fi
    printf '%s: PATH: could not rewrite the state file %s after the PATH change failed; the cli_path record in it is stale (nothing was written to PATH), so uninstall could remove an entry of the same text that you add by hand\n' \
        "$GSG_NAME" "$GSG_STATE_FILE" >&2
    return 1
}

# ^ invariant the one wording of the advice when a shell was open before the entry was added, by this install or an earlier one
install_path_new_shell_line() { printf '%s: PATH: a shell opened before this install does not see the change; open a new one\n' "$GSG_NAME"; }

# ^ invariant prints where the CLI is and what install did about PATH; an icon only in terminal mode, plain output is the words alone
install_path_report() {
    printf '%s: CLI: %s/%s\n' "$GSG_NAME" "$GSG_BIN_DIR" "$GSG_NAME"
    case "$INSTALL_PATH_ACTION" in
        onpath)
            printf '%s: PATH: %s is already on PATH; nothing was changed\n' "$GSG_NAME" "$GSG_BIN_DIR"
            return 0
            ;;
        present)
            printf '%s: PATH: %s; nothing was changed\n' "$GSG_NAME" "$INSTALL_PATH_WHY"
            install_path_new_shell_line
            return 0
            ;;
        add)
            printf '%s: PATH: %s\n' "$GSG_NAME" "$INSTALL_PATH_DONE"
            install_path_new_shell_line
            return 0
            ;;
    esac
    if [ "$INSTALL_PATH_ACTION" = failed ]; then ui_prefix 1 WARNING; else ui_prefix 1 info; fi
    printf '%s%s: PATH: %s is not on PATH (%s); to run %s by name, %s\n' \
        "$REPLY" "$GSG_NAME" "$GSG_BIN_DIR" "$INSTALL_PATH_WHY" "$GSG_NAME" "$(install_path_hint)"
}

# ^ invariant prints the by-hand step to put the CLI folder on PATH, no newline; install, status and doctor use the same words
# ^ external on Windows the folder is named as a Windows path (cygpath -w); a failing cygpath says why on stderr and the POSIX path is named instead
install_path_hint() {
    local w
    if tools_is_windows; then
        w="$(cygpath -w -- "$GSG_BIN_DIR")" || w="$GSG_BIN_DIR"
        printf 'add %s to the Path of your Windows user (System Properties, Environment Variables)' "$w"
        return 0
    fi
    printf 'add this line to your shell startup file: %s' "$GSG_PATH_LINE"
}

# ^ invariant prints the information line of status and doctor for a CLI folder not on the PATH they run with, no newline; read-only
install_path_missing_text() {
    printf '%s is not on the PATH this shell runs with, so %s is found by its full path only; %s' "$GSG_BIN_DIR" "$GSG_NAME" "$(install_path_hint)"
}

# ^ invariant with no record of ours nothing is touched, whatever a startup file holds; a changed block is named and left, a user line is never cut
# ^ invariant rc 1 only when a write fails, reason on stderr; the caller stops there and the next run finds the record still in the state
uninstall_path_entry() {
    case "${ST_CLI_PATH:-}" in
        "macos-block "*) ;;
        "windows-user-path "*)
            uninstall_path_entry_windows
            return
            ;;
        *) return 0 ;;
    esac
    if ! macpath_remove "$ST_CLI_PATH"; then
        printf '%s: cannot take the PATH block out: %s; fix that and run %s uninstall again\n' "$GSG_NAME" "$MACPATH_WHY" "$GSG_NAME" >&2
        return 1
    fi
    case "$MACPATH_RESULT" in
        removed)
            if [ -e "$MACPATH_RFILE" ]; then
                uninstall_say "removed the marked PATH block from $MACPATH_RFILE"
            else
                uninstall_say "removed the marked PATH block from $MACPATH_RFILE and the file itself, which install created"
            fi
            ;;
        left)
            ui_prefix 1 WARNING
            printf '%s%s: %s; left as it is\n' "$REPLY" "$GSG_NAME" "$MACPATH_WHY"
            ;;
    esac
}

# ^ invariant the Windows arm of uninstall_path_entry; winpath_remove deletes what apply appended, only if the value is unchanged
# ^ invariant every line names the folder of the record (Windows form), never GSG_BIN_DIR; the record may be for another folder than this install's
# ^ invariant an invalid record fails in winpath_remove (same split) before any line; folder is never empty where it is printed
uninstall_path_entry_windows() {
    local folder=""
    if state_winrec_split "$ST_CLI_PATH"; then folder="$ST_WINREC_FOLDER"; fi
    if ! winpath_remove "$ST_CLI_PATH"; then
        printf '%s: cannot take the folder out of the user Path: %s; fix that and run %s uninstall again\n' "$GSG_NAME" "$WINPATH_WHY" "$GSG_NAME" >&2
        return 1
    fi
    case "$REPLY" in
        removed)
            if [ "${WINPATH_NOBROADCAST:-0}" -eq 1 ]; then
                uninstall_say "removed $folder from the user Path; running programs could not be told, so sign out and in"
            else
                uninstall_say "removed $folder from the user Path"
            fi
            ;;
        changed)
            ui_prefix 1 WARNING
            printf '%s%s: the user Path holds %s in another spelling than install wrote; left as it is\n' "$REPLY" "$GSG_NAME" "$folder"
            ;;
    esac
}
