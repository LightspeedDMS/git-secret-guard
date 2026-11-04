# shellcheck shell=bash disable=SC2153

uninstall_say() {
    printf '%s: %s\n' "$GSG_NAME" "$1"
    GSG_UNINSTALL_ACTIONS=$((GSG_UNINSTALL_ACTIONS + 1))
}

uninstall_hook_section() {
    local rc
    hp_records config --global -z --get-regexp '^hook\.git-secret-guard\.'
    rc=$?
    if [ "$rc" -eq 1 ]; then return 0; fi
    if [ "$rc" -ne 0 ]; then
        hp_report_failure "git config" "$rc"
        return 1
    fi
    "$GSG_GIT" config --global --remove-section hook.git-secret-guard || {
        printf '%s: the hook.git-secret-guard section could not be removed from the global git config; run uninstall again\n' "$GSG_NAME" >&2
        return 1
    }
    uninstall_say "removed the hook.git-secret-guard section from the global git config"
}

# ^ invariant core.hooksPath is restored over an unset value only; a different current value is the user's newer choice and stays
uninstall_restore_hooks_path() {
    if [ "$ST_EXISTS" -ne 1 ] || [ "$ST_PREV_SET" != yes ]; then return 0; fi
    lifecycle_read_hooks_path || return 1
    if [ "${#GSG_HP_FOREIGN_FILE[@]}" -gt 0 ]; then
        printf '%s: core.hooksPath is set to [%s] in %s, not the recorded [%s]; left as it is\n' \
            "$GSG_NAME" "${GSG_HP_FOREIGN_VALUE[0]}" "${GSG_HP_FOREIGN_FILE[0]}" "$ST_PREV" >&2
        return 0
    fi
    if [ "${#GSG_HP_OWN[@]}" -gt 0 ]; then
        if [ "${#GSG_HP_OWN[@]}" -ne 1 ] || [ "${GSG_HP_OWN[0]}" != "$ST_PREV" ]; then
            printf '%s: core.hooksPath is now [%s], not the recorded [%s]; left as it is\n' "$GSG_NAME" "${GSG_HP_OWN[*]}" "$ST_PREV" >&2
        fi
        return 0
    fi
    "$GSG_GIT" config --global core.hooksPath "$ST_PREV" || {
        printf '%s: core.hooksPath not restored (git could not set it to [%s]); the hook config is left in place so commits stay scanned; fix the cause and run uninstall again\n' \
            "$GSG_NAME" "$ST_PREV" >&2
        return 1
    }
    uninstall_say "restored the previous core.hooksPath [$ST_PREV]"
}

# ^ security removes only a symlink whose text is our timer unit path and no longer resolves => links to anything else, live links and files stay
# ^ external systemctl --user enable links timers.target.wants/<timer> to the unit file; with the file gone disable is skipped and the link stays
uninstall_dangling_link() {
    local link="$GSG_UNIT_DIR/timers.target.wants/$GSG_TIMER_UNIT"
    if [ ! -L "$link" ] || [ -e "$link" ]; then return 0; fi
    if [ "$(readlink -- "$link")" != "$GSG_UNIT_DIR/$GSG_TIMER_UNIT" ]; then return 0; fi
    rm -f -- "$link" || return 1
    uninstall_say "removed the dangling enable link $link"
}

# ^ order uninstall_timer before uninstall_share_dir => the settings naming systemctl still exist; a failure keeps units, share dir and state for a rerun
# ^ security only units carrying the marker are disabled or removed; systemctl comes from the settings file, never from PATH
uninstall_timer() {
    local unit msg bin rc timer_mine=0
    local -a mine=()
    if [ "$ST_EXISTS" -ne 1 ] || [ "$ST_TIMER" != yes ]; then return 0; fi
    uninstall_dangling_link || return 1
    for unit in "$GSG_UNIT_DIR/$GSG_TIMER_UNIT" "$GSG_UNIT_DIR/$GSG_SERVICE_UNIT"; do
        if [ ! -e "$unit" ] && [ ! -L "$unit" ]; then continue; fi
        if timer_unit_is_ours "$unit"; then
            mine+=("$unit")
            if [ "${unit##*/}" = "$GSG_TIMER_UNIT" ]; then timer_mine=1; fi
        else
            printf '%s: %s was not written by git-secret-guard; left in place\n' "$GSG_NAME" "$unit" >&2
        fi
    done
    if [ "${#mine[@]}" -eq 0 ]; then return 0; fi
    if ! load_settings "$GSG_SHARE/settings" || msg="$(tool_unusable systemctl "${SYSTEMCTL_BIN:-}")"; then
        printf '%s: %s; the units, the share dir and the state are kept; run systemctl --user disable --now %s yourself, delete the unit files in %s and run uninstall again\n' \
            "$GSG_NAME" "${msg:-cannot read the settings}" "$GSG_TIMER_UNIT" "$GSG_UNIT_DIR" >&2
        return 1
    fi
    bin="$SYSTEMCTL_BIN"
    if [ "$timer_mine" -eq 1 ]; then
        "$bin" --user disable --now "$GSG_TIMER_UNIT"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '%s: could not disable %s (systemctl exit %s); the units, the share dir and the state are kept; fix the cause and run uninstall again\n' \
                "$GSG_NAME" "$GSG_TIMER_UNIT" "$rc" >&2
            return 1
        fi
    fi
    rm -f -- "${mine[@]}" || return 1
    "$bin" --user daemon-reload
    rc=$?
    if [ "$rc" -ne 0 ]; then
        printf '%s: removed the unit files but systemctl --user daemon-reload failed (exit %s); run it yourself, then run uninstall again\n' "$GSG_NAME" "$rc" >&2
        return 1
    fi
    if [ "$timer_mine" -eq 1 ]; then
        uninstall_say "disabled and removed the weekly doctor timer (${mine[*]})"
    else
        uninstall_say "removed the weekly doctor timer unit file(s) (${mine[*]}); there was no $GSG_TIMER_UNIT of ours to disable, so nothing was disabled"
    fi
}

# ^ order uninstall_agent before uninstall_share_dir => the settings naming launchctl still exist; a failure keeps plist, share dir and state for a rerun
# ^ security only a plist carrying the marker is unloaded or removed; launchctl comes from the settings file, never from PATH
# ^ why print before bootout, not bootout alone; bootout of an agent the user already unloaded fails, and uninstall would never finish
uninstall_agent() {
    local msg uid target rc present=1 unloaded=0 usable=1 kept="the plist, the share dir and the state"
    if [ "$ST_EXISTS" -ne 1 ] || [ "$ST_TIMER" != yes ]; then return 0; fi
    if [ ! -e "$GSG_AGENT_PLIST" ] && [ ! -L "$GSG_AGENT_PLIST" ]; then
        present=0
        kept="the share dir and the state"
    elif ! launchd_plist_is_ours "$GSG_AGENT_PLIST"; then
        printf '%s: %s was not written by git-secret-guard; left in place\n' "$GSG_NAME" "$GSG_AGENT_PLIST" >&2
        return 0
    fi
    uid="$(id -u)" || {
        printf '%s: cannot read the user id (id -u failed); %s are kept\n' "$GSG_NAME" "$kept" >&2
        return 1
    }
    target="gui/$uid/$GSG_LAUNCHD_LABEL"
    if ! load_settings "$GSG_SHARE/settings" || msg="$(tool_unusable launchctl "${LAUNCHCTL_BIN:-}")"; then
        # ^ why go on without a plist, not keep everything; nothing is left to remove and the loaded check cannot run; a rerun would stop the same way
        if [ "$present" -eq 1 ]; then
            printf '%s: %s; %s are kept; run launchctl bootout %s yourself, delete %s and run uninstall again\n' \
                "$GSG_NAME" "${msg:-cannot read the settings}" "$kept" "$target" "$GSG_AGENT_PLIST" >&2
            return 1
        fi
        printf '%s: %s; cannot check whether %s is still loaded; run launchctl bootout %s yourself if it is\n' \
            "$GSG_NAME" "${msg:-cannot read the settings}" "$GSG_LAUNCHD_LABEL" "$target" >&2
        usable=0
    fi
    if [ "$usable" -eq 1 ] && "$LAUNCHCTL_BIN" print "$target" >/dev/null 2>&1; then
        "$LAUNCHCTL_BIN" bootout "$target"
        rc=$?
        if [ "$rc" -ne 0 ]; then
            printf '%s: could not unload %s (launchctl exit %s); %s are kept; run launchctl bootout %s yourself or fix the cause, then run uninstall again\n' \
                "$GSG_NAME" "$GSG_LAUNCHD_LABEL" "$rc" "$kept" "$target" >&2
            return 1
        fi
        unloaded=1
    fi
    if [ "$present" -eq 1 ]; then rm -f -- "$GSG_AGENT_PLIST" || return 1; fi
    # ^ invariant the 00 outcome (no plist, not loaded) says nothing; uninstall_say would count an action and hide the final "nothing to do" line
    case "$present$unloaded" in
        11) uninstall_say "unloaded and removed the weekly doctor agent ($GSG_AGENT_PLIST)" ;;
        10) uninstall_say "removed the weekly doctor agent plist $GSG_AGENT_PLIST (the agent was not loaded)" ;;
        01) uninstall_say "unloaded the weekly doctor agent $GSG_LAUNCHD_LABEL (its plist $GSG_AGENT_PLIST was already gone)" ;;
    esac
    if [ -f "$GSG_AGENT_LOG" ] && [ ! -L "$GSG_AGENT_LOG" ]; then
        rm -f -- "$GSG_AGENT_LOG" || return 1
        uninstall_say "removed the weekly doctor agent log $GSG_AGENT_LOG"
    fi
}

uninstall_cli_link() {
    local link="$GSG_BIN_DIR/git-secret-guard"
    if [ ! -e "$link" ] && [ ! -L "$link" ]; then return 0; fi
    if [ -L "$link" ] && [ "$(readlink -- "$link")" = "$GSG_SHARE/bin/git-secret-guard" ]; then
        rm -f -- "$link" || return 1
        uninstall_say "removed the CLI link $link"
    else
        printf '%s: %s is not the link install created; left in place\n' "$GSG_NAME" "$link" >&2
    fi
}

# ^ invariant rm -rf only on an absolute path whose last component is git-secret-guard => a wrong XDG_DATA_HOME cannot point it at a user directory
uninstall_share_dir() {
    if [ ! -e "$GSG_SHARE" ]; then return 0; fi
    if [ "${GSG_SHARE#/}" = "$GSG_SHARE" ] || [ "${GSG_SHARE##*/}" != git-secret-guard ]; then
        printf '%s: refusing to remove %s: it is not an absolute path ending in git-secret-guard\n' "$GSG_NAME" "$GSG_SHARE" >&2
        return 1
    fi
    rm -rf -- "$GSG_SHARE" || return 1
    uninstall_say "removed the share dir $GSG_SHARE"
}

# ^ invariant UN_PLACED[tool] = every valid sha256 recorded for the tool, several after an unconfirmed placement; bad entries are reported
uninstall_read_placed() {
    local w
    local -a words=()
    declare -gA UN_PLACED=()
    read -r -a words <<<"$ST_PLACED"
    for w in "${words[@]}"; do
        if [[ $w =~ ^([a-z][a-z0-9-]*):([0-9a-f]{64})$ ]] && [[ " ${GSG_STATE_TOOL_NAMES[*]} " == *" ${BASH_REMATCH[1]} "* ]]; then
            UN_PLACED[${BASH_REMATCH[1]}]+="${UN_PLACED[${BASH_REMATCH[1]}]:+ }${BASH_REMATCH[2]}"
        else
            printf '%s: invalid tools_placed entry [%s] in the state file; ignored\n' "$GSG_NAME" "${w:0:80}" >&2
        fi
    done
}

# ^ security true only for a regular file (never a symlink) whose SHA-256 is one of the hashes in $2 => only a file install placed
uninstall_file_has_hash() {
    local path="$1" got h
    local -a want=()
    if [ -L "$path" ] || [ ! -f "$path" ]; then return 1; fi
    read -r -a want <<<"$2"
    got="$(sha256sum -- "$path" | cut -d' ' -f1)"
    if [ -z "$got" ]; then return 1; fi
    for h in "${want[@]}"; do
        if [ "$h" = "$got" ]; then return 0; fi
    done
    return 1
}

# ^ invariant records are "<tool>.gsg-replaced-<UTC stamp>:<sha256>" oldest first; the FIRST valid record per tool settles it, later ones are only reported
# ^ invariant guard = every tools_placed hash of the tool (the record hash in older states) => only install's own file or nothing is overwritten
# ^ invariant sets UN_HANDLED = " <tool> " for each tool with a valid record => uninstall_tools never deletes a tool whose original was restored or kept
uninstall_restore_replaced() {
    local entry aside sha tool path src guard decided=" "
    local -a words=()
    UN_HANDLED=" "
    read -r -a words <<<"$ST_REPLACED"
    for entry in "${words[@]}"; do
        aside="${entry%:*}"
        sha="${entry##*:}"
        tool="${aside%%.gsg-replaced-*}"
        if [[ $entry != *:* ]] || [[ ! $aside =~ $GSG_ASIDE_RE ]] || [[ ! $sha =~ ^[0-9a-f]{64}$ ]] \
            || [[ " ${GSG_STATE_TOOL_NAMES[*]} " != *" $tool "* ]]; then
            printf '%s: invalid tools_replaced entry [%s] in the state file; ignored\n' "$GSG_NAME" "${entry:0:80}" >&2
            continue
        fi
        path="$GSG_BIN_DIR/$tool"
        src="$GSG_BIN_DIR/$aside"
        UN_HANDLED+="$tool "
        if [[ $decided == *" $tool "* ]]; then
            printf '%s: another original of %s is kept at %s\n' "$GSG_NAME" "$tool" "$src"
            continue
        fi
        decided+="$tool "
        guard="${UN_PLACED[$tool]:-$sha}"
        if [ ! -e "$src" ] && [ ! -L "$src" ]; then
            # ^ order state is written before the move => a record without an aside beside a foreign file = the move never ran
            if { [ -e "$path" ] || [ -L "$path" ]; } && ! uninstall_file_has_hash "$path" "$guard"; then
                printf '%s: the planned move of %s never happened; it is still in place\n' "$GSG_NAME" "$path" >&2
            else
                printf '%s: your original %s is missing; %s is left as it is\n' "$GSG_NAME" "$src" "$path" >&2
            fi
            continue
        fi
        # ^ security install only ever places a regular file => a symlink or a different hash at the path is the user's newer choice, never overwritten
        if { [ -e "$path" ] || [ -L "$path" ]; } && ! uninstall_file_has_hash "$path" "$guard"; then
            printf '%s: %s is not the file install put there; left in place, your original stays at %s\n' "$GSG_NAME" "$path" "$src" >&2
            continue
        fi
        mv -T -f -- "$src" "$path" || {
            printf '%s: could not move your original %s back to %s\n' "$GSG_NAME" "$src" "$path" >&2
            return 1
        }
        uninstall_say "restored $path from $src (the file you had before install)"
    done
}

uninstall_tools() {
    local name
    local -a words=()
    if [ "$ST_EXISTS" -ne 1 ]; then
        printf '%s: no state file: cannot tell which tools install downloaded; none removed\n' "$GSG_NAME" >&2
        return 0
    fi
    read -r -a words <<<"$ST_TOOLS"
    for name in "${words[@]}"; do
        if [[ " ${GSG_STATE_TOOL_NAMES[*]} " != *" $name "* ]]; then
            printf '%s: unknown tool [%s] in the state file; not removed\n' "$GSG_NAME" "$name" >&2
            continue
        fi
        if [[ $UN_HANDLED == *" $name "* ]]; then continue; fi
        if [ ! -e "$GSG_BIN_DIR/$name" ] && [ ! -L "$GSG_BIN_DIR/$name" ]; then continue; fi
        # ^ security a tool is deleted only when its hash is one install recorded => a same-version build of the user's, a symlink or an unprovable file stays
        if [ -z "${UN_PLACED[$name]:-}" ] && [ -n "$ST_PLACED" ]; then
            printf '%s: the tools_placed entry for %s in the state file is invalid or missing; %s left in place\n' \
                "$GSG_NAME" "$name" "$GSG_BIN_DIR/$name" >&2
        elif [ -z "${UN_PLACED[$name]:-}" ]; then
            printf '%s: %s has no recorded hash of a file install placed (state written by an older install); left in place\n' \
                "$GSG_NAME" "$GSG_BIN_DIR/$name" >&2
        elif ! uninstall_file_has_hash "$GSG_BIN_DIR/$name" "${UN_PLACED[$name]}"; then
            printf '%s: %s is not the file install put there; left in place\n' "$GSG_NAME" "$GSG_BIN_DIR/$name" >&2
        else
            rm -f -- "$GSG_BIN_DIR/$name" || return 1
            uninstall_say "removed $GSG_BIN_DIR/$name (downloaded by install)"
        fi
    done
}

# ^ invariant doctor's record and temp files go with the state; the caller holds the findings lock, taken at the start of uninstall_run
# ^ coupled with lib/doctor_findings.sh owner of the record and the lock
uninstall_findings() {
    local f
    for f in "$GSG_FINDINGS_FILE" "$GSG_STATE_DIR"/findings.??????; do
        if [ -e "$f" ] || [ -L "$f" ]; then
            rm -f -- "$f" || {
                printf '%s: cannot remove %s\n' "$GSG_NAME" "$f" >&2
                return 1
            }
        fi
    done
}

uninstall_state() {
    if [ "$ST_EXISTS" -ne 1 ]; then return 0; fi
    # ^ order uninstall_findings before the state file goes => a refused lock or a failed delete leaves the state, and a rerun of uninstall finds work to do
    uninstall_findings || return 1
    rm -f -- "$GSG_STATE_FILE" || return 1
    uninstall_say "removed the state"
    if [ -n "$ST_BACKUP" ] && [ -e "$ST_BACKUP" ]; then
        printf '%s: the backup of your old hooks directory is kept at %s\n' "$GSG_NAME" "$ST_BACKUP"
    fi
}

# ^ order the findings lock is taken before anything is removed => a refused lock changes nothing and the installed CLI stays for the rerun
# ^ invariant uninstall_steps returns on many paths; the lock is released here, once, on all of them, and the state dir goes after it
# ^ why rmdir, not rm -r; a non-empty state dir holds the user's backup tarballs and must stay
uninstall_run() {
    local remove_tools="$1" rc
    GSG_UNINSTALL_ACTIONS=0
    paths_init || return 1
    lifecycle_note_global_config
    lifecycle_require_git || return 1
    state_read || return 1
    if [ "$ST_EXISTS" -eq 1 ] && ! doctor_rec_lock; then
        printf '%s: uninstall changed nothing; run %s uninstall again once no doctor run is active\n' "$GSG_NAME" "$GSG_NAME" >&2
        return 1
    fi
    uninstall_steps "$remove_tools"
    rc=$?
    doctor_rec_unlock || rc=1
    if [ "$rc" -eq 0 ] && [ "$ST_EXISTS" -eq 1 ]; then rmdir -- "$GSG_STATE_DIR" 2>/dev/null || true; fi
    return "$rc"
}

uninstall_steps() {
    local remove_tools="$1"
    # ^ order uninstall_restore_hooks_path before uninstall_hook_section => a failed restore leaves the hook config scanning, never a machine with neither
    uninstall_restore_hooks_path || return 1
    uninstall_hook_section || return 1
    if brew_is_macos; then uninstall_agent || return 1; else uninstall_timer || return 1; fi
    uninstall_cli_link || return 1
    uninstall_share_dir || return 1
    uninstall_read_placed || return 1
    uninstall_restore_replaced || return 1
    if [ "$remove_tools" -eq 1 ]; then uninstall_tools || return 1; fi
    uninstall_state || return 1
    if [ "$GSG_UNINSTALL_ACTIONS" -eq 0 ]; then
        printf '%s: nothing to do, git-secret-guard is not installed\n' "$GSG_NAME"
    fi
}
