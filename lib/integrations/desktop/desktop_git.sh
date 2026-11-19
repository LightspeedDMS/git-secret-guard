# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled install-time, status and doctor only; the CLI loads it after lib/gitup/gitup_source.sh and the hook never does
# ^ coupled the check (a commit through Desktop's own git) is desktop_git_check.sh, status and doctor text is desktop_git_report.sh
# ^ external Desktop for Linux (shiftkey fork) runs its bundled git 2.45.3, blind to config hooks; the renderer resets LOCAL_GIT_DIRECTORY

DESKTOP_GIT_MARKER='# git-secret-guard: written by install --link-desktop-git; undone by unlink-desktop-git'
DESKTOP_GIT_CHAIN_NAME=gsg-desktop-chain
DESKTOP_GIT_MAX_LINES=1000
# ^ external githooks(5) of git 2.45 and of 2.56 name 28 hooks, the 27 here leave out reference-transaction (test:test_the_event_list_matches_githooks_5)
# ^ why no reference-transaction wrapper, not a fast one; git runs it up to three times per ref update and a repository's own one is a stated limit
DESKTOP_GIT_EVENTS=(applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit prepare-commit-msg commit-msg post-commit pre-rebase
    post-checkout post-merge pre-push pre-receive update proc-receive post-receive post-update push-to-checkout pre-auto-gc
    post-rewrite sendemail-validate fsmonitor-watchman p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit post-index-change)

# ^ invariant sets REPLY = linux, macos or windows
desktop_git_platform() {
    if tools_is_windows; then
        REPLY=windows
    elif brew_is_macos; then
        REPLY=macos
    else
        REPLY=linux
    fi
}

# ^ invariant sets DG_BUNDLE, DG_GIT, DG_SYS_LAUNCHER, DG_USER_LAUNCHER, DG_HOOKS and DG_CHAIN; needs paths_init; GSG_GITUP_ROOT moves the system paths in tests
# ^ external the RPM and deb of the shiftkey fork use /usr/lib/github-desktop and /usr/share/applications; /opt, Flatpak and Snap layouts are not looked for
desktop_git_paths() {
    if [ -z "${GITUP_SYSTEM_PATH:-}" ]; then gitup_paths || return 1; fi
    DG_BUNDLE="$GITUP_ROOT/usr/lib/github-desktop/resources/app/git"
    DG_GIT="$DG_BUNDLE/bin/git"
    DG_SYS_LAUNCHER="$GITUP_ROOT/usr/share/applications/github-desktop.desktop"
    DG_USER_LAUNCHER="${XDG_DATA_HOME:-$HOME/.local/share}/applications/github-desktop.desktop"
    DG_HOOKS="$GSG_SHARE/desktop-hooks"
    DG_CHAIN="$DG_HOOKS/$DESKTOP_GIT_CHAIN_NAME"
}

# ^ invariant true when the git Desktop bundles is there and executable; the check runs it and nothing is written below its directory
desktop_git_found() { [ -f "$DG_GIT" ] && [ -x "$DG_GIT" ]; }

# ^ invariant true for a regular file (no link) with the marker on line 1 or line 2; a script starts with a shebang, a .desktop file with the marker
desktop_git_is_ours() {
    local l1="" l2=""
    if [ -L "$1" ] || [ ! -f "$1" ]; then return 1; fi
    { IFS= read -r l1 || [ -n "$l1" ]; IFS= read -r l2 || [ -n "$l2" ]; } <"$1" || true
    [ "$l1" = "$DESKTOP_GIT_MARKER" ] || [ "$l2" = "$DESKTOP_GIT_MARKER" ]
}

# ^ invariant true for a wrapper of ours; a relative link to the shared file, or a regular file with the marker (the form of an earlier run)
desktop_git_wrapper_is_ours() {
    if [ -L "$1" ]; then [ "$(readlink -- "$1")" = "$DESKTOP_GIT_CHAIN_NAME" ]; else desktop_git_is_ours "$1"; fi
}

# ^ invariant $1 = the directory, $2 = the event; makes $1/$2 a relative link to the shared file via a temp link and a rename; sets DG_CHANGED when it wrote
desktop_git_link_put() {
    local tmp="$1/.$2.new.$$"
    if [ -L "$1/$2" ] && [ "$(readlink -- "$1/$2")" = "$DESKTOP_GIT_CHAIN_NAME" ]; then return 0; fi
    rm -f -- "$tmp" || return 1
    if ! { ln -s -- "$DESKTOP_GIT_CHAIN_NAME" "$tmp" && mv -T -f -- "$tmp" "$1/$2"; }; then
        rm -f -- "$tmp"
        return 1
    fi
    DG_CHANGED=1
}

# ^ invariant prints lib/integrations/desktop/desktop-chain.sh with the marker on line 2 and its "scan=()" line replaced by the scan command of share $1
# ^ why baked in, not read from settings at run time; the wrapper stays one small file and fails as the config hook does
desktop_git_chain_text() {
    local share="$1" bash_bin line n=0
    local -a scan=()
    bash_bin="$(share_recorded_bash "$share")" || return 1
    if [ -n "$bash_bin" ]; then scan+=("$bash_bin"); fi
    scan+=("$share/hooks/secret-scan")
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$line" = 'scan=()' ]; then
            printf 'scan=(%s)\n' "$(printf '%q ' "${scan[@]}")"
        else
            printf '%s\n' "$line"
        fi
        if [ "$n" -eq 1 ]; then printf '%s\n' "$DESKTOP_GIT_MARKER"; fi
    done <"$GSG_ROOT/lib/integrations/desktop/desktop-chain.sh"
}

# ^ invariant $1 = the file, $2 = its text, $3 = the mode; written beside it and renamed, left alone when text and mode already match
# ^ invariant prints nothing and sets DG_CHANGED to 1 when the file was written
desktop_git_put() {
    local tmp
    if [ -f "$1" ] && [ ! -L "$1" ] && [ "$(<"$1")" = "${2%$'\n'}" ] && [ "$(stat -c %a -- "$1")" = "$3" ]; then return 0; fi
    tmp="$(mktemp "$1.new.XXXXXX")" || return 1
    if ! { printf '%s\n' "${2%$'\n'}" >"$tmp" && chmod "$3" "$tmp" && mv -f -- "$tmp" "$1"; }; then
        rm -f -- "$tmp"
        return 1
    fi
    DG_CHANGED=1
}

# ^ invariant prints the one Exec argument setting core.hooksPath to directory $1 in GIT_CONFIG_PARAMETERS; rc 1 = the path holds a control character
# ^ order git sq quoting first, next the Exec double quote (backslash before \ " ` $), next every \ doubled for the .desktop string layer, % doubled last
# ^ external Desktop Entry spec says a literal backslash in a quoted Exec argument takes four backslashes in the file, and % is a field code written %%
desktop_git_exec_arg() {
    local s q="'"
    if [[ $1 == *[[:cntrl:]]* ]]; then
        printf '%s: the hooks directory %q holds a control character; a launcher entry cannot carry it\n' "$GSG_NAME" "$1" >&2
        return 1
    fi
    s="GIT_CONFIG_PARAMETERS='core.hooksPath=${1//$q/$q\\$q$q}'"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//\`/\\\`}"
    s="${s//\$/\\\$}"
    s="${s//\\/\\\\}"
    printf '"%s"' "${s//%/%%}"
}

# ^ invariant prints the user launcher made from entry $1 for hooks directory $2; the marker, and every line with each Exec= run through env and our variable
# ^ why a copy of the whole entry, not a patch file; the user entry replaces the system one by name and nothing of Desktop's file is written
# ^ hazard a future DBusActivatable=true in the system entry would start Desktop over D-Bus without its Exec= line and our variable would not reach it
desktop_git_launcher_text() {
    local arg line n=0
    arg="$(desktop_git_exec_arg "$2")" || return 1
    printf '%s\n' "$DESKTOP_GIT_MARKER"
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        if [ "$n" -gt "$DESKTOP_GIT_MAX_LINES" ]; then
            printf '%s: %s has more than %s lines; it is not a launcher entry\n' "$GSG_NAME" "$1" "$DESKTOP_GIT_MAX_LINES" >&2
            return 1
        fi
        if desktop_git_exec_value "$line"; then line="Exec=env $arg $REPLY"; fi
        printf '%s\n' "$line"
    done <"$1"
}

# ^ invariant rc 0 and REPLY = the value when line $1 is an Exec key as GLib's KeyFile reads it; blanks before the key and around the = are allowed
# ^ external the last duplicate key of a group wins in GLib; every spelling counts as an Exec line, not only a line starting Exec=
desktop_git_exec_value() {
    local re='^[[:space:]]*Exec[[:space:]]*=[[:space:]]*(.*)$'
    if [[ $1 =~ $re ]]; then
        REPLY="${BASH_REMATCH[1]}"
    else
        return 1
    fi
}

# ^ invariant prints the first file of hooks directory $1 (shared file and wrappers) found and not ours; rc 1 = none
desktop_git_foreign_in() {
    local f
    if { [ -e "$1/$DESKTOP_GIT_CHAIN_NAME" ] || [ -L "$1/$DESKTOP_GIT_CHAIN_NAME" ]; } && ! desktop_git_is_ours "$1/$DESKTOP_GIT_CHAIN_NAME"; then
        printf '%s' "$1/$DESKTOP_GIT_CHAIN_NAME"
        return 0
    fi
    for f in "${DESKTOP_GIT_EVENTS[@]/#/$1/}"; do
        if { [ -e "$f" ] || [ -L "$f" ]; } && ! desktop_git_wrapper_is_ours "$f"; then
            printf '%s' "$f"
            return 0
        fi
    done
    return 1
}

# ^ invariant prints the first file of the link (user launcher, shared file, wrappers) found and not ours; rc 1 = none
desktop_git_foreign() {
    if { [ -e "$DG_USER_LAUNCHER" ] || [ -L "$DG_USER_LAUNCHER" ]; } && ! desktop_git_is_ours "$DG_USER_LAUNCHER"; then
        printf '%s' "$DG_USER_LAUNCHER"
        return 0
    fi
    desktop_git_foreign_in "$DG_HOOKS"
}

# ^ invariant rc 0 = the launcher path and the hooks directory are valid UTF-8; rc 1 = one is not (named on stderr); rc 2 = iconv itself failed
# ^ external GLib returns no launcher for a file name or Exec value not in UTF-8 (g_desktop_app_info_new_from_filename is NULL); such a link never works
desktop_git_paths_utf8_ok() {
    local p rc
    for p in "$DG_USER_LAUNCHER" "$DG_HOOKS"; do
        printf '%s' "$p" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1
        rc=$?
        if [ "$rc" -eq 1 ]; then
            printf '%s: the path %q is not valid UTF-8, so GLib cannot load a launcher entry that names it\n' "$GSG_NAME" "$p" >&2
            return 1
        elif [ "$rc" -eq 127 ]; then
            printf '%s: iconv is not installed; --link-desktop-git needs it to check that the launcher path is valid UTF-8\n' "$GSG_NAME" >&2
            return 2
        elif [ "$rc" -ne 0 ]; then
            printf '%s: iconv failed (status %s) while checking the path of the launcher entry\n' "$GSG_NAME" "$rc" >&2
            return 2
        fi
    done
}

# ^ invariant DESKTOP_GIT_FLAG is 1 for install --link-desktop-git; a global as lib/install/install.sh is at its size limit; a refusal here stops install
# ^ order runs after paths_init and before the git offers and every other write => a refusal changes nothing, and says so
desktop_git_precheck() {
    local f
    if [ "${DESKTOP_GIT_FLAG:-0}" -ne 1 ]; then return 0; fi
    desktop_git_platform
    if [ "$REPLY" != linux ]; then
        printf '%s: --link-desktop-git is for GitHub Desktop on Linux (its bundled git is the old one); on %s update Desktop instead; %s.\n' "$GSG_NAME" "$REPLY" "$(brew_unchanged_text)" >&2
        return 1
    fi
    desktop_git_paths || return 1
    if ! desktop_git_found; then
        printf '%s: --link-desktop-git: GitHub Desktop was not found (no executable %s; only the RPM and deb layout is looked for, not Flatpak, Snap or /opt); %s.\n' "$GSG_NAME" "$DG_GIT" "$(brew_unchanged_text)" >&2
        return 1
    fi
    if [ ! -f "$DG_SYS_LAUNCHER" ] || [ ! -r "$DG_SYS_LAUNCHER" ]; then
        printf '%s: --link-desktop-git: cannot read the launcher entry %s the user entry is made from; %s.\n' "$GSG_NAME" "$DG_SYS_LAUNCHER" "$(brew_unchanged_text)" >&2
        return 1
    fi
    if ! desktop_git_paths_utf8_ok; then
        printf '%s: --link-desktop-git refused, Desktop would start unscanned; %s.\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
        return 1
    fi
    if [ -L "$DG_HOOKS" ] || { [ -e "$DG_HOOKS" ] && [ ! -d "$DG_HOOKS" ]; }; then
        printf '%s: --link-desktop-git: %s is a symbolic link or not a directory; install will not write through it; %s.\n' "$GSG_NAME" "$DG_HOOKS" "$(brew_unchanged_text)" >&2
        return 1
    fi
    if f="$(desktop_git_foreign)"; then
        local advice='Move it out of the hooks directory (a hook of yours belongs in the repository or in a directory of your own)'
        if [ "$f" = "$DG_USER_LAUNCHER" ]; then advice='Move it away (or add the environment by hand)'; fi
        printf '%s: --link-desktop-git: %s exists and git-secret-guard did not write it; it is kept, install will not replace it. %s and run install --link-desktop-git again; %s.\n' "$GSG_NAME" "$f" "$advice" "$(brew_unchanged_text)" >&2
        return 1
    fi
}

# ^ invariant desktop_git_hooks_write SHARE DIR makes DIR with the shared file and one wrapper per event; a file without the marker stops it before any write
# ^ security the shared file goes first and a wrapper only after it => an interrupted run leaves wrappers naming a file there
desktop_git_hooks_write() {
    local share="${1:-}" dir="${2:-}" ev f text
    DG_CHANGED=0
    if [ -z "$share" ] || [ ! -d "$share" ] || [ -z "$dir" ]; then
        printf '%s: internal error: desktop_git_hooks_write needs the share dir and the hooks dir, got [%s] [%s]\n' "$GSG_NAME" "$share" "$dir" >&2
        return 1
    fi
    if [ -L "$dir" ] || { [ -e "$dir" ] && [ ! -d "$dir" ]; }; then
        printf '%s: %s is a symbolic link or not a directory; install --link-desktop-git will not write through it; nothing was changed\n' "$GSG_NAME" "$dir" >&2
        return 1
    fi
    if f="$(desktop_git_foreign_in "$dir")"; then
        printf '%s: %s is not a file install --link-desktop-git wrote; nothing was changed\n' "$GSG_NAME" "$f" >&2
        return 1
    fi
    mkdir -p -- "$dir" || return 1
    text="$(desktop_git_chain_text "$share")" || return 1
    desktop_git_put "$dir/$DESKTOP_GIT_CHAIN_NAME" "$text" 755 || return 1
    for ev in "${DESKTOP_GIT_EVENTS[@]}"; do
        desktop_git_link_put "$dir" "$ev" || return 1
    done
}

# ^ invariant writes the user launcher from the current system entry; DG_CHANGED is not reset, the caller counts the hooks directory too
# ^ security a file without the marker is never replaced
desktop_git_launcher_write() {
    local text
    if { [ -e "$DG_USER_LAUNCHER" ] || [ -L "$DG_USER_LAUNCHER" ]; } && ! desktop_git_is_ours "$DG_USER_LAUNCHER"; then
        printf '%s: %s is not a file install --link-desktop-git wrote; it is kept\n' "$GSG_NAME" "$DG_USER_LAUNCHER" >&2
        return 1
    fi
    desktop_git_paths_utf8_ok || return 1
    text="$(desktop_git_launcher_text "$DG_SYS_LAUNCHER" "$DG_HOOKS")" || return 1
    mkdir -p -- "${DG_USER_LAUNCHER%/*}" || return 1
    desktop_git_put "$DG_USER_LAUNCHER" "$text" 644
}

# ^ invariant undoes a failed run by removing the files of the link, and says how many went or a removal failed
desktop_git_rollback() {
    if desktop_git_unlink_files; then
        printf '%s: GitHub Desktop was not linked; %s files of the link (written by this run or an earlier one) were removed again\n' "$GSG_NAME" "$DG_REMOVED" >&2
    else
        printf '%s: GitHub Desktop was not linked, but removing the files of the link failed after %s files; run %s unlink-desktop-git\n' "$GSG_NAME" "$DG_REMOVED" "$GSG_NAME" >&2
    fi
}

# ^ invariant $1 = 1 when the user asked (the check always runs), 0 for a refresh of a link; rc 1 = a step failed and the link was rolled back
# ^ order the hooks directory is written before the check and the check runs before the launcher => the launcher only points at a checked directory
desktop_git_apply() {
    local asked="${1:-}" ver verified=""
    case "$asked" in 0 | 1) ;; *)
        printf '%s: internal error: desktop_git_apply needs 0 or 1, got [%s]\n' "$GSG_NAME" "$asked" >&2
        return 1
        ;;
    esac
    ver="$(install_git_version "$DG_GIT")" || ver="of unknown version"
    DG_CHANGED=0
    desktop_git_hooks_write "$GSG_SHARE" "$DG_HOOKS" || {
        desktop_git_rollback
        return 1
    }
    if [ "$asked" -eq 1 ] || [ "$DG_CHANGED" -eq 1 ] || [ ! -f "$DG_USER_LAUNCHER" ]; then
        verified="$(desktop_git_check_run "$DG_HOOKS")" || {
            desktop_git_rollback
            return 1
        }
    fi
    desktop_git_launcher_write || {
        desktop_git_rollback
        return 1
    }
    if [ "$DG_CHANGED" -eq 1 ]; then
        printf '%s: GitHub Desktop (git %s): wrote the hooks directory %s (%s wrappers) and the launcher entry %s\n' "$GSG_NAME" "$ver" "$DG_HOOKS" "${#DESKTOP_GIT_EVENTS[@]}" "$DG_USER_LAUNCHER"
    else
        printf '%s: GitHub Desktop (git %s): the hooks directory and the launcher entry are current; nothing was changed\n' "$GSG_NAME" "$ver"
    fi
    if [ -n "$verified" ]; then printf '%s\n' "$verified"; fi
    if [ "$DG_CHANGED" -eq 1 ]; then
        printf '%s: restart GitHub Desktop to use it, from the applications menu; the launcher entry sets core.hooksPath for Desktop and its git only. Desktop started any other way, for example from a terminal, is not covered. The repository'\''s own hooks still run (chained).\n' "$GSG_NAME"
    fi
}

# ^ invariant removes what install --link-desktop-git wrote and nothing else; launcher first, wrappers next, the directory last when empty
# ^ invariant sets DG_REMOVED to the number of files removed; a file without the marker is named on stderr and kept; rc 1 only when a removal failed
# ^ invariant sets DG_KEPT to 1 when the hooks directory itself is still there (a foreign file in it, or a link or file at its path); uninstall needs it
desktop_git_unlink_files() {
    local f
    local -a files=("$DG_USER_LAUNCHER")
    DG_REMOVED=0 DG_KEPT=0
    if [ -L "$DG_HOOKS" ] || { [ -e "$DG_HOOKS" ] && [ ! -d "$DG_HOOKS" ]; }; then
        printf '%s: %s is a symbolic link or not a directory; it and what it holds are left in place\n' "$GSG_NAME" "$DG_HOOKS" >&2
        DG_KEPT=1
    else
        files+=("$DG_CHAIN" "${DESKTOP_GIT_EVENTS[@]/#/$DG_HOOKS/}")
    fi
    for f in "${files[@]}"; do
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
        if ! desktop_git_wrapper_is_ours "$f" && ! desktop_git_is_ours "$f"; then
            printf '%s: %s was not written by git-secret-guard; left in place\n' "$GSG_NAME" "$f" >&2
            continue
        fi
        rm -f -- "$f" || return 1
        DG_REMOVED=$((DG_REMOVED + 1))
    done
    if [ -d "$DG_HOOKS" ] && [ ! -L "$DG_HOOKS" ]; then
        for f in "$DG_HOOKS"/.*.new.* "$DG_HOOKS/$DESKTOP_GIT_CHAIN_NAME".new.*; do
            if { [ -e "$f" ] || [ -L "$f" ]; } && desktop_git_leftover_is_ours "$f"; then
                rm -f -- "$f" || return 1
                DG_REMOVED=$((DG_REMOVED + 1))
            fi
        done
        rmdir -- "$DG_HOOKS" 2>/dev/null || true
        if [ -d "$DG_HOOKS" ]; then
            DG_KEPT=1
            desktop_git_name_unlisted
        fi
    fi
}

# ^ invariant names the entries of the hooks directory with no hook name (the others were named already), at most 3 and a count, on stderr
desktop_git_name_unlisted() {
    local f ev n=0 listed
    for f in "$DG_HOOKS"/* "$DG_HOOKS"/.[!.]* "$DG_HOOKS"/..?*; do
        if [ ! -e "$f" ] && [ ! -L "$f" ]; then continue; fi
        listed=0
        for ev in "$DESKTOP_GIT_CHAIN_NAME" "${DESKTOP_GIT_EVENTS[@]}"; do
            if [ "${f##*/}" = "$ev" ]; then listed=1; fi
        done
        if [ "$listed" -eq 1 ]; then continue; fi
        n=$((n + 1))
        if [ "$n" -le "$DESKTOP_GIT_NAMES_SHOWN" ]; then printf '%s: %s was not written by git-secret-guard; left in place\n' "$GSG_NAME" "${f//[[:cntrl:]]/?}" >&2; fi
    done
    if [ "$n" -gt "$DESKTOP_GIT_NAMES_SHOWN" ]; then printf '%s: and %s more files in %s were not written by git-secret-guard; left in place\n' "$GSG_NAME" "$((n - DESKTOP_GIT_NAMES_SHOWN))" "$DG_HOOKS" >&2; fi
}

# ^ invariant true for a temp entry an interrupted write left in the hooks directory; a link to the shared file, or an empty or marked copy of it
# ^ why the target and the marker decide, not the name alone; a file of the user's matching the pattern stays
desktop_git_leftover_is_ours() {
    if [ -L "$1" ]; then
        [ "$(readlink -- "$1")" = "$DESKTOP_GIT_CHAIN_NAME" ]
    elif [[ ${1##*/} == "$DESKTOP_GIT_CHAIN_NAME".new.* ]] && [ -f "$1" ]; then
        [ ! -s "$1" ] || desktop_git_is_ours "$1"
    else
        return 1
    fi
}

# ^ invariant true when the shared file or the launcher is ours; a finished link has both, an interrupted run leaves one
desktop_git_linked() { desktop_git_is_ours "$DG_USER_LAUNCHER" || desktop_git_is_ours "$DG_CHAIN"; }

# ^ invariant the unlink-desktop-git command; removes only files with the marker and touches nothing of Desktop or /usr
desktop_git_unlink_run() {
    paths_init || return 1
    desktop_git_paths || return 1
    desktop_git_unlink_files || return 1
    ui_prefix 1 ok
    if [ "$DG_REMOVED" -eq 0 ]; then
        printf '%s%s: nothing to unlink, install --link-desktop-git has not changed anything here\n' "$REPLY" "$GSG_NAME"
        return 0
    fi
    printf '%s%s: removed %s files of the GitHub Desktop link; restart GitHub Desktop so it stops using them\n' "$REPLY" "$GSG_NAME" "$DG_REMOVED"
}

# ^ invariant uninstall's step; the link goes before the share dir holding the hooks directory and counts as one action when files were removed
# ^ why stop, not go on; the hooks directory is inside the share dir and removing the share dir would delete the file this step kept
# ^ order the stop comes before the hook config and the state change => the rerun after the user moved the file away finds everything it needs
desktop_git_uninstall_step() {
    desktop_git_paths || return 1
    desktop_git_unlink_files || return 1
    if [ "$DG_KEPT" -eq 1 ]; then
        if [ "$DG_REMOVED" -gt 0 ]; then uninstall_say "removed $DG_REMOVED files of the GitHub Desktop link"; fi
        printf '%s: uninstall stopped: %s is inside the share dir and still holds what is named above; move them away and run uninstall again; the hook and the state are unchanged\n' "$GSG_NAME" "$DG_HOOKS" >&2
        return 1
    fi
    if [ "$DG_REMOVED" -gt 0 ]; then uninstall_say "removed the GitHub Desktop link ($DG_REMOVED files, the launcher entry and the hooks directory)"; fi
}

# ^ invariant keeps the hooks directory through the swap of the share dir; a commit made in Desktop during an upgrade still finds its wrappers
# ^ invariant GSG_SHARE_NEW is the new tree
desktop_git_carry_over() {
    if [ ! -d "$GSG_SHARE/desktop-hooks" ]; then return 0; fi
    cp -a -- "$GSG_SHARE/desktop-hooks" "$GSG_SHARE_NEW/"
}

# ^ invariant install's last step, after the share dir is in place; Linux links when asked (DESKTOP_GIT_FLAG=1) or refreshes a link, else prints one note
# ^ invariant the other platforms get the update note of lib/integrations/desktop/desktop_git_report.sh; rc 1 = the link failed and was rolled back
desktop_git_install_step() {
    local ver
    desktop_git_platform
    if [ "$REPLY" != linux ]; then
        desktop_git_other_note
        return 0
    fi
    desktop_git_paths || return 1
    if ! desktop_git_found; then return 0; fi
    if [ "${DESKTOP_GIT_FLAG:-0}" -eq 1 ]; then
        # ^ why clear after the link, not before; a signal in the self-check or a failed link leaves the flag set and install_cleanup prints the warning
        if desktop_git_apply 1; then
            DG_WARN_HELD=0
            return 0
        fi
        return 1
    fi
    if desktop_git_linked; then
        desktop_git_apply 0
        return
    fi
    ver="$(install_git_version "$DG_GIT")" || {
        ui_prefix 2 WARNING
        printf '%s%s: note: GitHub Desktop was found but %s did not report a git version; if it is older than 2.54 its commits are not scanned (install --link-desktop-git fixes that)\n' "$REPLY" "$GSG_NAME" "$DG_GIT" >&2
        return 0
    }
    if install_git_is_new_enough "$DG_GIT"; then return 0; fi
    ui_prefix 1 WARNING
    printf '%s%s: note: GitHub Desktop (git %s) runs its own git, which ignores the scan hook without any message, so commits made in Desktop are not scanned; to scan them run: %s install --link-desktop-git\n' "$REPLY" "$GSG_NAME" "$ver" "$GSG_NAME"
}
