# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled status, doctor and install notes for GitHub Desktop; loaded by bin/git-secret-guard after desktop_git_check.sh, never by the hook
# ^ invariant Linux judges the files install --link-desktop-git wrote; macOS and Windows only recommend updating Desktop (their bundled git is newer)

DESKTOP_GIT_NAMES_SHOWN=3

# ^ invariant sets REPLY = where GitHub Desktop was found on macOS or Windows, "" when it was not; rc 1 = not found
# ^ external only the default places count (/Applications and ~/Applications on macOS, %LOCALAPPDATA%\GitHubDesktop on Windows); docs/platforms.md says so
# ^ security GSG_GITUP_ROOT moves /Applications into a sandbox for tests like the other system paths; nothing is written here
desktop_git_other_path() {
    local dir platform
    if [ -z "${GITUP_SYSTEM_PATH:-}" ]; then gitup_paths || return 1; fi
    desktop_git_platform
    platform="$REPLY"
    REPLY=""
    case "$platform" in
        macos) set -- "$GITUP_ROOT/Applications/GitHub Desktop.app" "$HOME/Applications/GitHub Desktop.app" ;;
        windows)
            if [ -z "${LOCALAPPDATA:-}" ]; then return 1; fi
            set -- "$(gsg_posix_path "$LOCALAPPDATA")/GitHubDesktop"
            ;;
        *) return 1 ;;
    esac
    for dir in "$@"; do
        if [ -d "$dir" ]; then
            REPLY="$dir"
            return 0
        fi
    done
    return 1
}

# ^ invariant install's note for macOS and Windows; nothing is printed when Desktop is not in a place desktop_git_other_path knows
# ^ external Desktop 3.6.10 for macOS and Windows bundles git 2.56.0 (read from its code, not run); an older Desktop may bundle an older git
desktop_git_other_note() {
    local where
    if ! desktop_git_other_path; then return 0; fi
    where="$REPLY"
    ui_prefix 1 WARNING
    printf '%s%s: note: GitHub Desktop was found at %s; update it to the latest release: its bundled git must be 2.54 or newer to run the scan hook, an older one ignores it without any message\n' "$REPLY" "$GSG_NAME" "$where"
}

# ^ invariant status line for macOS and Windows, a WARNING (the user should update Desktop) and never a problem; nothing is printed when Desktop is not found
desktop_git_other_status() {
    if ! desktop_git_other_path; then return 0; fi
    status_line WARNING "GitHub Desktop" "found at $REPLY; update it to the latest release (its bundled git must be 2.54 or newer to run the scan hook; its version is not read here)"
}

# ^ invariant doctor line for macOS and Windows, information only
desktop_git_other_doctor() {
    if ! desktop_git_other_path; then return 0; fi
    doctor_machine_line info "GitHub Desktop: found at $REPLY; update it to the latest release (its bundled git must be 2.54 or newer to run the scan hook; its version is not read here)"
}

# ^ invariant true when git $1 is the one Desktop bundles and its link is active; install and doctor skip their old-git warning for it
desktop_git_covers() {
    install_git_is_bundled "$1" || return 1
    desktop_git_paths || return 1
    desktop_git_state
    [ "$DG_STATE" = active ]
}

# ^ invariant true for Desktop's bundled git when this run tries to link it (the flag, or desktop_git_auto_wanted of desktop_git.sh)
# ^ order install_report_other_gits runs before the link step => deciding there would print a warning the link lines contradict
# ^ invariant sets DG_WARN_HELD=1 when it is true; the Desktop step clears it after a good link, and install_cleanup prints the held warning if it is still set
desktop_git_hold_warning() {
    if ! install_git_is_bundled "$1"; then return 1; fi
    if [ "${DESKTOP_GIT_FLAG:-0}" -ne 1 ]; then desktop_git_auto_wanted || return 1; fi
    DG_WARN_HELD=1
}

# ^ invariant $1 = the function reporting for macOS and Windows; rc 0 = Linux, state set; rc 2 = $1 reported, nothing more to say; rc 1 = paths failed
desktop_git_linux_state() {
    desktop_git_platform
    if [ "$REPLY" != linux ]; then
        "$1"
        return 2
    fi
    desktop_git_paths || return 1
    desktop_git_state
}

# ^ invariant status line for GitHub Desktop; MISMATCH is a problem (exit 1), not linked a WARNING (the user acts), a current link ok, scanning by config info
desktop_git_status_lines() {
    local rc=0
    desktop_git_linux_state desktop_git_other_status || rc=$?
    if [ "$rc" -eq 2 ]; then return 0; fi
    if [ "$rc" -ne 0 ]; then return 1; fi
    case "$DG_STATE" in
        none) ;;
        mismatch) status_line PROBLEM "GitHub Desktop" "$DG_TEXT" ;;
        unlinked) status_line WARNING "GitHub Desktop" "$DG_TEXT" ;;
        active) status_line ok "GitHub Desktop" "$DG_TEXT" ;;
        *) status_line info "GitHub Desktop" "$DG_TEXT" ;;
    esac
}

# ^ invariant doctor line for GitHub Desktop; a stale link is a PROBLEM (it promised to scan), an unlinked old git is information (a plain install links it)
desktop_git_doctor_lines() {
    local rc=0
    desktop_git_linux_state desktop_git_other_doctor || rc=$?
    if [ "$rc" -eq 2 ]; then return 0; fi
    if [ "$rc" -ne 0 ]; then return 1; fi
    case "$DG_STATE" in
        none) ;;
        active) doctor_machine_line ok "GitHub Desktop: $DG_TEXT" ;;
        mismatch)
            if [ "$DG_SOFT" -eq 1 ]; then doctor_machine_line WARNING "GitHub Desktop: $DG_TEXT"; else doctor_machine_line PROBLEM "GitHub Desktop: $DG_TEXT"; fi
            ;;
        *) doctor_machine_line info "GitHub Desktop: $DG_TEXT" ;;
    esac
}

# ^ invariant prints the names of hooks directory files not executable, not ours or not what install would write now, comma separated and cut
# ^ why compared with the generated text, not with a version number; a changed recorded bash, share path or product version shows up as the stale file it is
# ^ invariant rc 1 = the expected text could not be built and nothing was compared
desktop_git_stale_names() {
    local ev f want n=0 names=""
    want="$(desktop_git_chain_text "$GSG_SHARE")" || return 1
    for f in "$DESKTOP_GIT_CHAIN_NAME" "${DESKTOP_GIT_EVENTS[@]}"; do
        ev="$DG_HOOKS/$f"
        if [ "$f" = "$DESKTOP_GIT_CHAIN_NAME" ]; then
            if [ -f "$ev" ] && [ ! -L "$ev" ] && [ -x "$ev" ] && [ "$(<"$ev")" = "$want" ]; then continue; fi
        elif [ -L "$ev" ] && [ "$(readlink -- "$ev")" = "$DESKTOP_GIT_CHAIN_NAME" ]; then
            continue
        fi
        n=$((n + 1))
        if [ "$n" -le "$DESKTOP_GIT_NAMES_SHOWN" ]; then names+="${names:+, }$f"; fi
    done
    if [ "$n" -gt "$DESKTOP_GIT_NAMES_SHOWN" ]; then names+=" and $((n - DESKTOP_GIT_NAMES_SHOWN)) more"; fi
    printf '%s' "$names"
}

# ^ invariant rc 0 = launcher file $1 has an Exec line and every Exec line starts with the env call carrying our exact core.hooksPath argument for directory $2
# ^ why the exact argument, not a substring; a changed directory or a plain Exec line starts Desktop with the old git and no scan
desktop_git_launcher_sets_path() {
    local arg line n=0 execs=0
    arg="$(desktop_git_exec_arg "$2")" || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$n" -gt "$DESKTOP_GIT_MAX_LINES" ]; then return 1; fi
        if ! desktop_git_exec_value "$line"; then continue; fi
        execs=$((execs + 1))
        if [[ $REPLY != "env $arg "* ]]; then return 1; fi
    done <"$1"
    [ "$execs" -gt 0 ]
}

# ^ invariant sets DG_STATE to none, unlinked (old Desktop git, nothing of ours), scans (Desktop git 2.54 or newer, nothing of ours), active or mismatch
# ^ invariant DG_TEXT is the status text after the Desktop label (MISMATCH and the command for mismatch), DG_VER the git version; needs desktop_git_paths
desktop_git_state() {
    local stale want fix="run: $GSG_NAME install"
    DG_STATE=none DG_TEXT="" DG_VER="" DG_SOFT=0
    if desktop_git_found; then DG_VER="$(install_git_version "$DG_GIT")" || DG_VER="of unknown version"; fi
    if ! desktop_git_linked; then
        if [ -z "$DG_VER" ]; then return 0; fi
        if install_git_is_new_enough "$DG_GIT"; then
            DG_STATE=scans DG_TEXT="git $DG_VER runs the scan hook itself; no link is needed"
        else
            DG_STATE=unlinked DG_TEXT="git $DG_VER is not linked, so commits made in Desktop are not scanned; $fix"
        fi
        return 0
    fi
    DG_STATE=mismatch
    if [ -z "$DG_VER" ]; then
        DG_TEXT="MISMATCH GitHub Desktop was not found but its link is still there; run: $GSG_NAME unlink-desktop-git"
        return 0
    fi
    stale="$(desktop_git_stale_names)" || stale="the files could not be compared"
    if [ -n "$stale" ]; then
        DG_TEXT="MISMATCH the hooks directory is missing or has changed files ($stale); $fix"
    elif [ ! -f "$DG_USER_LAUNCHER" ]; then
        DG_TEXT="MISMATCH the launcher entry is missing; $fix"
    elif ! want="$(desktop_git_launcher_text "$DG_SYS_LAUNCHER" "$DG_HOOKS" 2>/dev/null)"; then
        DG_TEXT="MISMATCH the system launcher entry $DG_SYS_LAUNCHER cannot be read; $fix"
    elif [ "$(<"$DG_USER_LAUNCHER")" != "$want" ]; then
        if desktop_git_launcher_sets_path "$DG_USER_LAUNCHER" "$DG_HOOKS"; then
            # ^ why soft, not a problem; every Exec line still carries our core.hooksPath, Desktop's update only changed what the system entry says
            DG_SOFT=1 DG_TEXT="MISMATCH the launcher entry differs from the system entry it is made from; $fix"
        else
            DG_TEXT="MISMATCH the launcher entry no longer sets core.hooksPath for Desktop; $fix"
        fi
    else
        DG_STATE=active DG_TEXT="linked (git $DG_VER); the ${#DESKTOP_GIT_EVENTS[@]} wrappers, the shared file and the launcher entry are current"
    fi
}
