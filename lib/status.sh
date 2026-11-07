# shellcheck shell=bash disable=SC2153

status_line() { printf '%s: %s\n' "$1" "$2"; }

# ^ invariant sets STATUS_PROBLEMS += 1 for every line printed with MISMATCH or MISSING => the exit code is 1 exactly when one was printed
status_problem() {
    STATUS_PROBLEMS=$((STATUS_PROBLEMS + 1))
}

status_config() {
    local events commands want_cmd
    want_cmd="$(hook_command_text "$GSG_SHARE" "$(share_recorded_bash "$GSG_SHARE")")" || return 1
    events="$("$GSG_GIT" config --global --get-all hook.git-secret-guard.event 2>/dev/null | tr '\n' ' ')"
    commands="$("$GSG_GIT" config --global --get-all hook.git-secret-guard.command 2>/dev/null | tr '\n' ' ')"
    if [ "$events" = "pre-commit " ] && [ "$commands" = "$want_cmd " ]; then
        status_line "global config" "matches (hook.git-secret-guard.event=pre-commit, .command=$want_cmd)"
    else
        status_line "global config" "MISMATCH (event=[${events% }] want [pre-commit]; command=[${commands% }] want [$want_cmd])"
        status_problem
    fi
}

status_hook_command() {
    local cmd="$GSG_SHARE/hooks/secret-scan"
    if [ -f "$cmd" ] && [ -x "$cmd" ]; then
        status_line "hook command" "$cmd"
    else
        status_line "hook command" "$cmd (MISSING or not executable)"
        status_problem
    fi
}

# ^ external git config --show-scope exists from git 2.26; an older git is a MISMATCH on the git line already, the scope lines say not read
status_git_lists_scopes() {
    local ver
    ver="$(install_git_version "$GSG_GIT" 2>/dev/null)" || return 1
    gitup_version_at_least "$ver" 2.26
}

# ^ invariant a switched-off or valueless hook.<name>.enabled is a MISMATCH naming key, scope, file and for an off hook its value, never command or event
# ^ coupled the scan judges by git's own parser, last scope wins; below git 2.26 there is no --show-scope, the line says not checked
status_hook_enabled() {
    local i value adv origin
    if ! status_git_lists_scopes; then
        status_line "hook enabled" "not checked (the git in use is older than 2.26 or unreadable, and cannot list config scopes)"
        return 0
    fi
    if ! hp_hook_enabled_scan; then
        status_line "hook enabled" "MISMATCH cannot read the git config${GSG_HP_ERR:+: $GSG_HP_ERR}"
        status_problem
        return 0
    fi
    for i in "${!HP_EN_KIND[@]}"; do
        hp_hook_enabled_advice "$i"
        adv="$REPLY"
        origin="${HP_EN_ORIGIN[$i]#file:}"
        origin="${origin//[^[:print:]]/?}"
        value="${HP_EN_VALUE[$i]//[^[:print:]]/?}"
        trunc_text "$value" 40
        value="$REPLY"
        case "${HP_EN_KIND[$i]}" in
            valueless)
                status_line "hook enabled" "MISMATCH ${HP_EN_KEY[$i]} has no value in the ${HP_EN_SCOPE[$i]} config ($origin); git commands fail until it is removed; $adv"
                status_problem
                ;;
            ignored) status_line "hook enabled" "${HP_EN_KEY[$i]}=$value in the ${HP_EN_SCOPE[$i]} config ($origin) is not a boolean, git ignores it" ;;
            default) status_line "hook enabled" "${HP_EN_KEY[$i]}=$value in the ${HP_EN_SCOPE[$i]} config ($origin) is not a boolean and no other value is set, so git's default applies and the hook stays on" ;;
            unjudged)
                status_line "hook enabled" "MISMATCH ${HP_EN_KEY[$i]} could not be judged (the boolean probe failed: $value); the hook may be switched off"
                status_problem
                ;;
            *)
                status_line "hook enabled" "MISMATCH ${HP_EN_KEY[$i]}=$value in the ${HP_EN_SCOPE[$i]} config ($origin) switches the hook off, commits are not scanned; $adv"
                status_problem
                ;;
        esac
    done
    if [ "${#HP_EN_KIND[@]}" -eq 0 ]; then status_line "hook enabled" "yes (neither hook.git-secret-guard.enabled nor hook.pre-commit.enabled switches it off)"; fi
}

# ^ invariant informational only => config hooks run whatever core.hooksPath says, this line never counts as a problem
status_hooks_path() {
    local i list=""
    lifecycle_read_hooks_path || return 1
    for i in "${!GSG_HP_OWN[@]}"; do
        list+="${list:+; }${GSG_HP_OWN[$i]} (${GSG_HP_FILE#file:})"
    done
    for i in "${!GSG_HP_FOREIGN_FILE[@]}"; do
        list+="${list:+; }${GSG_HP_FOREIGN_VALUE[$i]} (${GSG_HP_FOREIGN_FILE[$i]})"
    done
    status_line "core.hooksPath (effective)" "${list:-unset}"
}

status_tool() {
    local name="$1" bin="$2" pinned="$3"
    if tool_unusable "$name" "$bin" >/dev/null; then
        status_line "$name" "$bin (MISSING or not executable)"
        status_problem
        return 0
    fi
    if tools_probe_version "$bin" "$pinned" "$TIMEOUT_BIN"; then
        status_line "$name" "$bin $TOOL_FOUND (pinned $pinned) ok"
    else
        status_line "$name" "$bin $TOOL_FOUND (pinned $pinned) MISMATCH"
        status_problem
    fi
}

status_tools() {
    local tool plat row bin
    if ! load_settings "$GSG_SHARE/settings" 2>/dev/null; then
        status_line "settings" "$GSG_SHARE/settings (MISSING or unreadable)"
        status_problem
        return 0
    fi
    if tool_unusable timeout "${TIMEOUT_BIN:-}" >/dev/null; then
        status_line "timeout" "${TIMEOUT_BIN:-} (MISSING or not executable)"
        status_problem
        return 0
    fi
    GSG_OS="$(uname -s)" && GSG_ARCH="$(uname -m)" || return 1
    for tool in "${GSG_TOOL_NAMES[@]}"; do
        plat="$(tools_platform_key "$tool" "$GSG_OS" "$GSG_ARCH" 2>/dev/null)" || plat=""
        row="$(tools_lock_lookup "$(tools_lock_path)" "$tool" "$plat" 2>/dev/null)" || row="none none"
        bin="$(settings_tool_bin "$tool")" || return 1
        status_tool "$tool" "$bin" "${row%% *}"
    done
    for tool in jq "$(gsg_proc_tool_name)" timeout; do
        bin="$(settings_tool_bin "$tool")" || return 1
        if tool_unusable "$tool" "$bin" >/dev/null; then
            status_line "$tool" "$bin (MISSING or not executable)"
            status_problem
        else
            status_line "$tool" "$bin"
        fi
    done
}

# ^ invariant one line for a class whose module has the takeover capability; a takeover undone by something else is a MISMATCH and a problem
status_system_git() {
    if ! gitup_system_git_state; then return 0; fi
    case "$GITUP_TK_STATE" in
        none | active) status_line "system git takeover" "$GITUP_TK_TEXT" ;;
        *)
            status_line "system git takeover" "MISMATCH $GITUP_TK_TEXT"
            status_problem
            ;;
    esac
}

# ^ invariant an interrupted source copy (MANIFEST.partial) is shown with its next step; it is not counted as a problem
status_unfinished_copy() {
    if gitup_source_unfinished_copy; then status_line "git build" "$REPLY"; fi
}

# ^ invariant names the first git on PATH and its version on every run; older than 2.54 (or unreadable) is a problem => its config hooks never fire
# ^ coupled a second old git behind the first is not judged here, doctor reports it
status_git() {
    local ver
    if ! ver="$(install_git_version "$GSG_GIT")"; then
        status_line "git in use" "$(gitup_display_path "$GSG_GIT") (version unreadable; if it is older than 2.54 commits are not scanned) MISMATCH"
        status_problem
    elif install_git_is_new_enough "$GSG_GIT"; then
        status_line "git in use" "$(gitup_display_path "$GSG_GIT") (git $ver)"
    else
        status_line "git in use" "$(gitup_display_path "$GSG_GIT") (git $ver) MISMATCH: config hooks need git >= 2.54, so commits are not scanned; run: $GSG_NAME install --upgrade-git"
        status_problem
    fi
}

status_run() {
    STATUS_PROBLEMS=0
    paths_init || return 1
    lifecycle_note_global_config
    lifecycle_require_git || return 1
    state_read || return 1
    if [ -z "${GITUP_SYSTEM_PATH:-}" ]; then gitup_paths || return 1; fi
    status_git
    if [ "$ST_EXISTS" -ne 1 ]; then
        printf '%s: not installed (no state file at %s)\n' "$GSG_NAME" "$GSG_STATE_FILE"
        if gitup_system_git_state && [ "$GITUP_TK_STATE" != none ]; then status_system_git; fi
        status_unfinished_copy
        return 1
    fi
    status_line "installed version" "$ST_VERSION"
    status_line "share dir" "$GSG_SHARE"
    status_hook_command
    status_config
    status_hook_enabled
    if [ "$ST_PREV_SET" = yes ]; then
        status_line "previous core.hooksPath" "$ST_PREV"
    else
        status_line "previous core.hooksPath" "unset"
    fi
    if status_git_lists_scopes; then
        status_hooks_path || return 1
    else
        status_line "core.hooksPath (effective)" "not read (the git in use cannot list config scopes)"
    fi
    status_line "hooks backup" "${ST_BACKUP:-none}"
    status_line "tools installed by us" "${ST_TOOLS:-none}"
    local entry asides=""
    for entry in $ST_REPLACED; do
        asides+="${asides:+ }${entry%:*}"
    done
    status_line "originals moved aside" "${asides:-none}"
    status_tools || return 1
    status_system_git
    status_unfinished_copy
    [ "$STATUS_PROBLEMS" -eq 0 ]
}
