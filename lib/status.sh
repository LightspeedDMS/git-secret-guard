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

status_run() {
    STATUS_PROBLEMS=0
    paths_init || return 1
    lifecycle_note_global_config
    lifecycle_require_git || return 1
    state_read || return 1
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
    if [ "$ST_PREV_SET" = yes ]; then
        status_line "previous core.hooksPath" "$ST_PREV"
    else
        status_line "previous core.hooksPath" "unset"
    fi
    status_hooks_path || return 1
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
