# shellcheck shell=bash disable=SC2153,SC2034
# ^ coupled CLI-only library for the Windows side of the updater, loaded after lib/autoupdate/autoupdate.sh; the hook never loads it
# ^ invariant autoupdate_role and bin/git-secret-guard reach it on Windows only, every other platform runs the code it had before

# ^ invariant winupdate_git CEILING ARGS... runs git with the GIT_* repository variables unset and the walk up from the checkout stopped at CEILING
# ^ security the GIT_DIR of a calling hook cannot point the probe at another repository, and no parent directory is searched for one
# ^ hazard no limit on this call; it reads one local directory and runs before the settings (and their timeout) are loaded
winupdate_git() {
    local ceiling="$1"
    shift
    env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE -u GIT_OBJECT_DIRECTORY -u GIT_NAMESPACE -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
        GIT_CEILING_DIRECTORIES="$ceiling" "${GSG_GIT:?winupdate_git needs GSG_GIT}" "$@"
}

# ^ external [ -O ] is true for a directory of any owner under MSYS (probed with Guest, SYSTEM and half-owned repositories); git decides
# ^ external git exits 128 for dubious ownership and for no repository alike; the answer .git (the repository starts here) tells a repository
# ^ invariant prints owner when git takes checkout $1 as it is, follower with safe.directory=$1 only, rc 1 and nothing when it is no repository
winupdate_role() {
    local ceiling out
    # ^ external native git reads the ceiling as C:/dir, not /c/dir; the parent of the checkout is the first directory it may not enter
    ceiling="${1%/*}"
    ceiling="$(cygpath -m "${ceiling:-/}")" || return 1
    # ^ security safe.directory is reset on the command line; a user-level safe.directory=* cannot make another account's checkout look like mine
    if out="$(winupdate_git "$ceiling" -c safe.directory= -C "$1" rev-parse --git-dir 2>/dev/null)" && [ "$out" = .git ]; then
        printf 'owner\n'
        return 0
    fi
    if out="$(winupdate_git "$ceiling" -c "safe.directory=$1" -C "$1" rev-parse --git-dir 2>/dev/null)" && [ "$out" = .git ]; then
        printf 'follower\n'
        return 0
    fi
    return 1
}

# ^ invariant a copy of the share left by a killed run is removed by the next run once it is this many minutes old; a younger one may belong to a live run
GSG_UPDATE_COPY_MAX_AGE_MIN=1440

# ^ invariant rc 0 = this process runs from the private copy GSG_UPDATE_COPY names; an inherited value naming nothing of ours counts for nothing
winupdate_in_copy() {
    tools_is_windows && [ -n "${GSG_UPDATE_COPY:-}" ] && [ -d "$GSG_UPDATE_COPY" ] && [ "$GSG_ROOT" -ef "$GSG_UPDATE_COPY" ]
}

# ^ invariant rc 1 = a failed run is recorded through the record writer of autoupdate.sh, with no reason (the record's word for a failure without one)
# ^ invariant $1 = the cause; the installed version goes into the record, and the line is printed as update prints a failure
winupdate_failed() {
    AU_ROLE="" AU_TO="" AU_FROM=""
    autoupdate_installed_version
    AU_FROM="$REPLY"
    autoupdate_outcome failed "" "$1"
    autoupdate_record_write || true
    ui_prefix 2 PROBLEM
    printf '%s%s: update: failed: %s\n' "$REPLY" "$GSG_NAME" "$1" >&2
    return 1
}

# ^ external Windows refuses to rename a directory with a running script or a working directory in it (probed), and install swaps the share by two renames
# ^ external exec keeps the MSYS pid and drops the old Windows process (probed); the update lock the new process takes names the pid it holds
# ^ invariant rc 0 = nothing to do here (not Windows, already the copy, not run from the share, auto-update off); otherwise exec ends this shell
winupdate_reexec() {
    local copy
    if ! tools_is_windows || winupdate_in_copy; then return 0; fi
    paths_init || return 1
    if [ ! -d "$GSG_SHARE" ] || ! [ "$GSG_ROOT" -ef "$GSG_SHARE" ]; then return 0; fi
    state_read || return 1
    if [ "$ST_EXISTS" -ne 1 ] || [ "$ST_AUTO_UPDATE" != yes ]; then return 0; fi
    # ^ invariant the copy holds bin, lib, VERSION and settings in a private dir of the state dir; the state is read first, an off updater copies nothing
    if ! find "$GSG_STATE_DIR" -maxdepth 1 -type d -name 'update-copy.??????' -mmin "+$GSG_UPDATE_COPY_MAX_AGE_MIN" -exec rm -rf -- {} +; then
        printf '%s: cannot remove old update copies in %s\n' "$GSG_NAME" "$GSG_STATE_DIR" >&2
    fi
    copy="$(umask 077 && mktemp -d "$GSG_STATE_DIR/update-copy.XXXXXX")" || { winupdate_failed "cannot make a private copy dir in $GSG_STATE_DIR"; return; }
    if ! cp -R -- "$GSG_ROOT/bin" "$GSG_ROOT/lib" "$GSG_ROOT/VERSION" "$copy/" || { [ -f "$GSG_ROOT/settings" ] && ! cp -- "$GSG_ROOT/settings" "$copy/"; }; then
        rm -rf -- "$copy"
        winupdate_failed "cannot copy $GSG_ROOT to a private copy in $GSG_STATE_DIR"
        return
    fi
    export GSG_UPDATE_COPY="$copy"
    cd -- "$GSG_STATE_DIR" || { rm -rf -- "$copy"; winupdate_failed "cannot enter $GSG_STATE_DIR"; return; }
    exec "$BASH" "$copy/bin/$GSG_NAME" update
}

# ^ invariant removes the private copy this process runs from, only a real directory named update-copy.?????? in the state dir; a failure is said, never fatal
# ^ external a running script's directory can be deleted on Windows (probed), only renaming it is refused
winupdate_drop_copy() {
    local copy="${GSG_UPDATE_COPY:-}"
    if ! winupdate_in_copy; then return 0; fi
    case "$copy" in
        "$GSG_STATE_DIR"/update-copy.??????) ;;
        *) return 0 ;;
    esac
    if [ -L "$copy" ]; then return 0; fi
    cd -- "$GSG_STATE_DIR" || return 0
    if ! rm -rf -- "$copy"; then printf '%s: cannot remove %s\n' "$GSG_NAME" "$copy" >&2; fi
}

# ^ invariant the entry point of "git-secret-guard update", from a private copy of the share on Windows; the exit status is autoupdate_run's
# ^ why GCM_INTERACTIVE=never here, not in the re-exec only; a run by hand makes no copy and Git Credential Manager waits for an unseen window
winupdate_run() {
    local rc=0
    # ^ why unset the two, not keep them; either one stops the path conversion native git needs, and its /c/dir paths find no repository
    if tools_is_windows; then unset MSYS_NO_PATHCONV MSYS2_ARG_CONV_EXCL; fi
    if tools_is_windows; then export GCM_INTERACTIVE=never; fi
    winupdate_reexec || return 1
    autoupdate_run || rc=$?
    winupdate_drop_copy
    return "$rc"
}
