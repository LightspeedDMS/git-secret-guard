# shellcheck shell=bash disable=SC2153,SC2034

DR_PROBLEMS=0
DR_WARNINGS=0
DR_REPO_TOTAL=0
DR_REPO_COVERED=0
DR_WORK=""
DR_GITLEAKS_OK=0
DR_TIMEOUT_OK=0
DR_LIMIT=""
GSG_DOCTOR_TIMEOUT_DEFAULT=30

# ^ invariant every machine line goes through here => severity is counted once and control characters never reach the terminal
doctor_machine_line() {
    local text="${2//[[:cntrl:]]/?}"
    case "$1" in
        PROBLEM) DR_PROBLEMS=$((DR_PROBLEMS + 1)) ;;
        WARNING) DR_WARNINGS=$((DR_WARNINGS + 1)) ;;
    esac
    printf '  %-8s %s\n' "$1" "$text"
}

# ^ external a git config -z record = "key NL value"; a valueless key is just "key" and its value is empty, never the key
# ^ invariant sets REC_KEY and REC_VALUE
doctor_split_record() {
    REC_KEY="${1%%$'\n'*}"
    REC_VALUE=""
    if [[ $1 == *$'\n'* ]]; then REC_VALUE="${1#*$'\n'}"; fi
}

doctor_is_false() {
    case "${1,,}" in false | no | off | 0) return 0 ;; esac
    return 1
}

# shellcheck disable=SC2329
doctor_cleanup() {
    # ^ invariant rm -rf only on the absolute mktemp directory this run made
    if [ -n "$DR_WORK" ] && [ "${DR_WORK#/}" != "$DR_WORK" ]; then rm -rf -- "$DR_WORK"; fi
}

# ^ security pathspec and replace-object variables are dropped or pinned before any HEAD read => an inherited setting cannot change what is judged
# ^ security the repository-local GIT_* variables are unset => GIT_DIR from a calling hook cannot point every check at one repository
# ^ invariant GIT_OPTIONAL_LOCKS=0 => no git command run here refreshes an index
doctor_start() {
    local v vars
    DR_WORK="$(mktemp -d)" || {
        printf '%s: cannot create a temp directory\n' "$GSG_NAME" >&2
        return 1
    }
    trap doctor_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    unset GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
    vars="$("$GSG_GIT" rev-parse --local-env-vars 2>"$DR_WORK/start.err")" || {
        first_message "$DR_WORK/start.err"
        printf '%s: git cannot start the checks (%s)\n' "$GSG_NAME" "${REPLY//[[:cntrl:]]/?}" >&2
        return 1
    }
    while IFS= read -r v; do
        if [ -n "$v" ]; then unset "$v"; fi
    done <<<"$vars"
    # ^ security doctor reads other people's repositories => no command their config names may run and no remote may be contacted
    # ^ hazard fsmonitor runs on index reads, a partial clone fetches missing blobs from its promisor; test:test_doctor_runs_no_command_a_repository_configures
    # ^ external GIT_CONFIG_COUNT is command scope, beats repository config and must follow the unset loop; the hook never loads this file
    export GIT_NO_REPLACE_OBJECTS=1 GIT_OPTIONAL_LOCKS=0 GIT_NO_LAZY_FETCH=1
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.fsmonitor GIT_CONFIG_VALUE_0=false
}

doctor_require_git() {
    local ver
    lifecycle_require_git || return 1
    if ! install_git_is_new_enough "$GSG_GIT"; then
        ver="$(install_git_version "$GSG_GIT")" || ver="of unknown version"
        printf '%s: the git on PATH (%s) is git %s; doctor needs git >= 2.54 to see config-based hooks\n' "$GSG_NAME" "$GSG_GIT" "$ver" >&2
        return 1
    fi
}

# ^ invariant sets DR_ROOT_LIST = absolute real paths of existing directories; a missing one is a doctor error, never skipped
doctor_resolve_roots() {
    local root
    DR_ROOT_LIST=()
    if [ "$#" -eq 0 ]; then
        set -- "$HOME/Dev"
        if [ ! -d "$1" ]; then
            printf '%s: default root %s is not a directory; pass --roots DIR\n' "$GSG_NAME" "$1" >&2
            return 1
        fi
    fi
    for root in "$@"; do
        if [ ! -d "$root" ]; then
            printf '%s: root %s is not a directory\n' "$GSG_NAME" "${root//[[:cntrl:]]/?}" >&2
            return 1
        fi
        DR_ROOT_LIST+=("$(realpath -- "$root")") || return 1
    done
}

doctor_check_state() {
    if ! state_read 2>"$DR_WORK/state.err"; then
        first_message "$DR_WORK/state.err"
        doctor_machine_line PROBLEM "state: $REPLY"
        return 0
    fi
    if [ "$ST_EXISTS" -ne 1 ]; then
        doctor_machine_line PROBLEM "installed: not installed (no state file at $GSG_STATE_FILE); run git-secret-guard install"
        return 0
    fi
    doctor_machine_line ok "installed: version $ST_VERSION (state $GSG_STATE_FILE)"
    doctor_check_state_records
}

# ^ invariant a tools_placed word = <tool>:<sha256> of a managed tool; two hashes for one tool = an unfinished install
# ^ invariant a tools_replaced word is <tool>.gsg-replaced-<UTC stamp>:<sha256>, the same shape uninstall_restore_replaced accepts
doctor_check_state_records() {
    local w tool hash aside sha flagged=0 placed_n=0 replaced_n=0
    local -a words=() hs=()
    local -A hashes=()
    read -r -a words <<<"$ST_TOOLS"
    for w in "${words[@]}"; do
        if [[ " ${GSG_TOOL_NAMES[*]} " != *" $w "* ]]; then
            trunc_text "$w" 80
            doctor_machine_line PROBLEM "state: tools_installed_by_us names [$REPLY], not a tool install manages"
            flagged=1
        fi
    done
    read -r -a words <<<"$ST_PLACED"
    for w in "${words[@]}"; do
        if [[ $w =~ ^([a-z][a-z0-9-]*):([0-9a-f]{64})$ ]] && [[ " ${GSG_TOOL_NAMES[*]} " == *" ${BASH_REMATCH[1]} "* ]]; then
            tool="${BASH_REMATCH[1]}" hash="${BASH_REMATCH[2]}"
            if [[ " ${hashes[$tool]:-} " != *" $hash "* ]]; then
                hashes[$tool]+="${hashes[$tool]:+ }$hash"
                placed_n=$((placed_n + 1))
            fi
        else
            trunc_text "$w" 80
            doctor_machine_line PROBLEM "state: tools_placed entry [$REPLY] is invalid (want <tool>:<sha256>)"
            flagged=1
        fi
    done
    for tool in "${GSG_TOOL_NAMES[@]}"; do
        read -r -a hs <<<"${hashes[$tool]:-}"
        if [ "${#hs[@]}" -gt 1 ]; then
            doctor_machine_line WARNING "state: tools_placed holds ${#hs[@]} hashes for $tool, an install did not finish placing it; run git-secret-guard install again"
            flagged=1
        fi
    done
    read -r -a words <<<"$ST_REPLACED"
    for w in "${words[@]}"; do
        aside="${w%:*}" sha="${w##*:}" tool="${aside%%.gsg-replaced-*}"
        if [[ $w != *:* ]] || [[ ! $aside =~ $GSG_ASIDE_RE ]] || [[ ! $sha =~ ^[0-9a-f]{64}$ ]] || [[ " ${GSG_TOOL_NAMES[*]} " != *" $tool "* ]]; then
            trunc_text "$w" 80
            doctor_machine_line PROBLEM "state: tools_replaced entry [$REPLY] is invalid"
            flagged=1
        elif [ ! -e "$GSG_BIN_DIR/$aside" ] && [ ! -L "$GSG_BIN_DIR/$aside" ]; then
            doctor_machine_line WARNING "state: tools_replaced records $aside but $GSG_BIN_DIR/$aside is missing; a rerun of install drops a record of a move that never happened, otherwise your original cannot be restored"
            flagged=1
        else
            replaced_n=$((replaced_n + 1))
        fi
    done
    if [ "$flagged" -eq 0 ]; then
        doctor_machine_line ok "state records: $placed_n placed hash(es), $replaced_n original(s) moved aside"
    fi
}

# ^ security a configured value is never printed, only count, origin and matches => a global command can hold a token and the timer logs this output
# ^ invariant sets REPLY = "has N value(s) (scope file; ...), K of them <label>"
doctor_values_text() {
    local n="$1" ok="$2" src="$3" label="$4" noun=values
    if [ "$n" -eq 1 ]; then noun=value; fi
    REPLY="has $n $noun ($src), $ok of them $label"
}

# ^ external git config --show-scope --show-origin -z --get-regexp = "scope NUL origin NUL key NL value NUL" (probed on git 2.56)
# ^ why -C /, not the current directory; the machine view must not include a repository's local config
doctor_check_hook_config() {
    local rc i scope origin value want="$GSG_SHARE/hooks/secret-scan" bad=0 msg
    local ev_n=0 ev_ok=0 ev_src="" cmd_n=0 cmd_ok=0 cmd_src=""
    hp_records -C / config --show-scope --show-origin -z --get-regexp '^hook\.git-secret-guard\.'
    rc=$?
    if [ "$rc" -gt 1 ]; then
        doctor_machine_line PROBLEM "hook: cannot read the git config (git config exit $rc${GSG_HP_ERR:+: $GSG_HP_ERR})"
        return 0
    fi
    for ((i = 0; i + 2 < ${#GSG_HP_OUT[@]}; i += 3)); do
        scope="${GSG_HP_OUT[i]}"
        origin="${GSG_HP_OUT[i + 1]}"
        doctor_split_record "${GSG_HP_OUT[i + 2]}"
        value="$REC_VALUE"
        case "$REC_KEY" in
            hook.git-secret-guard.event)
                ev_n=$((ev_n + 1))
                ev_src+="${ev_src:+; }$scope ${origin#file:}"
                if [ "$value" = pre-commit ]; then ev_ok=$((ev_ok + 1)); fi
                ;;
            hook.git-secret-guard.command)
                cmd_n=$((cmd_n + 1))
                cmd_src+="${cmd_src:+; }$scope ${origin#file:}"
                if [ "$value" = "$(gsg_hook_command)" ]; then cmd_ok=$((cmd_ok + 1)); fi
                ;;
            hook.git-secret-guard.enabled)
                if doctor_is_false "$value"; then
                    doctor_machine_line PROBLEM "hook: hook.git-secret-guard.enabled=$value in the $scope config (${origin#file:}) switches the hook off everywhere; remove it"
                    bad=1
                fi
                ;;
        esac
    done
    if [ "$ev_n" -eq 0 ]; then
        doctor_machine_line PROBLEM "hook: hook.git-secret-guard.event is [unset], want exactly [pre-commit]; run git-secret-guard install"
        bad=1
    elif [ "$ev_n" -ne 1 ] || [ "$ev_ok" -ne 1 ]; then
        doctor_values_text "$ev_n" "$ev_ok" "$ev_src" pre-commit
        doctor_machine_line PROBLEM "hook: hook.git-secret-guard.event $REPLY, want exactly one, pre-commit; run git-secret-guard install"
        bad=1
    fi
    if [ "$cmd_n" -eq 0 ]; then
        doctor_machine_line PROBLEM "hook: hook.git-secret-guard.command is [unset], want exactly [$want]; run git-secret-guard install"
        bad=1
    elif [ "$cmd_n" -ne 1 ] || [ "$cmd_ok" -ne 1 ]; then
        doctor_values_text "$cmd_n" "$cmd_ok" "$cmd_src" "the installed hook"
        doctor_machine_line PROBLEM "hook: hook.git-secret-guard.command $REPLY, want exactly one, the installed hook [$want]; run git-secret-guard install"
        bad=1
    elif msg="$(tool_unusable "hook command" "$want")"; then
        doctor_machine_line PROBLEM "hook: $msg; run git-secret-guard install"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then
        doctor_machine_line ok "hook: hook.git-secret-guard.event=pre-commit, command=$want (executable)"
    fi
}

# ^ invariant prints the version tools.lock pins for this platform; rc 1 when there is no row
doctor_pinned() {
    local plat row
    GSG_OS="$(uname -s)" && GSG_ARCH="$(uname -m)" || return 1
    plat="$(tools_platform_key "$1" "$GSG_OS" "$GSG_ARCH" 2>/dev/null)" || return 1
    row="$(tools_lock_lookup "$(tools_lock_path)" "$1" "$plat" 2>/dev/null)" || return 1
    printf '%s' "${row%% *}"
}

doctor_check_tools() {
    local tool bin msg pinned timeout_ok=0
    DR_GITLEAKS_OK=0 DR_TIMEOUT_OK=0 DR_LIMIT=""
    if ! load_settings "$GSG_SHARE/settings" 2>"$DR_WORK/settings.err"; then
        first_message "$DR_WORK/settings.err"
        doctor_machine_line PROBLEM "settings: ${REPLY:-$GSG_SHARE/settings is invalid}; run git-secret-guard install"
        return 0
    fi
    if ! tool_unusable timeout "$(settings_tool_bin timeout)" >/dev/null; then timeout_ok=1; fi
    DR_TIMEOUT_OK="$timeout_ok"
    # ^ invariant DR_LIMIT = seconds per git call and per gitleaks pre-flight, empty = invalid setting; the shim also needs DR_TIMEOUT_OK=1 or runs no git
    DR_LIMIT="${DOCTOR_TIMEOUT_SECONDS-$GSG_DOCTOR_TIMEOUT_DEFAULT}"
    if [[ ! $DR_LIMIT =~ ^[1-9][0-9]{0,5}$ ]]; then
        trunc_text "$DR_LIMIT" 40
        doctor_machine_line PROBLEM "settings: DOCTOR_TIMEOUT_SECONDS must be a positive integer, got [$REPLY]; fix or remove it in $GSG_SHARE/settings"
        DR_LIMIT=""
    fi
    for tool in "${GSG_TOOL_NAMES[@]}"; do
        bin="$(settings_tool_bin "$tool")"
        if msg="$(tool_unusable "$tool" "$bin")"; then
            doctor_machine_line PROBLEM "$tool: $msg; run git-secret-guard install"
        elif [ "$timeout_ok" -ne 1 ]; then
            doctor_machine_line PROBLEM "$tool: $bin version not checked, timeout is unusable"
        elif ! pinned="$(doctor_pinned "$tool")"; then
            doctor_machine_line PROBLEM "$tool: tools.lock has no pinned version for this platform"
        elif tools_probe_version "$bin" "$pinned" "$TIMEOUT_BIN"; then
            doctor_machine_line ok "$tool: $bin $TOOL_FOUND (pinned $pinned)"
        else
            doctor_machine_line PROBLEM "$tool: $bin reports $TOOL_FOUND, the pin is $pinned; run git-secret-guard install"
        fi
    done
    for tool in jq "$(gsg_proc_tool_name)" timeout; do
        bin="$(settings_tool_bin "$tool")"
        if msg="$(tool_unusable "$tool" "$bin")"; then
            doctor_machine_line PROBLEM "$tool: $msg; run git-secret-guard install"
        else
            doctor_machine_line ok "$tool: $bin"
        fi
    done
    if [ "$timeout_ok" -eq 1 ] && [ -n "$DR_LIMIT" ] && ! tool_unusable gitleaks "$GITLEAKS_BIN" >/dev/null; then DR_GITLEAKS_OK=1; fi
}

# ^ invariant read-only; systemctl is judged like the hook's tools and never run, a run inside the user manager cannot fail on a bus
doctor_check_timer() {
    local unit path msg bin bad=0
    if [ "$ST_EXISTS" -ne 1 ] || [ "$ST_TIMER" != yes ]; then return 0; fi
    for unit in "$GSG_TIMER_UNIT" "$GSG_SERVICE_UNIT"; do
        path="$GSG_UNIT_DIR/$unit"
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then
            doctor_machine_line PROBLEM "timer: $path is missing; run git-secret-guard install --with-timer"
            bad=1
        elif ! timer_unit_is_ours "$path"; then
            doctor_machine_line PROBLEM "timer: $path was not written by git-secret-guard; move it away and run git-secret-guard install --with-timer"
            bad=1
        fi
    done
    bin="$(settings_tool_bin systemctl)"
    if msg="$(tool_unusable systemctl "$bin")"; then
        doctor_machine_line PROBLEM "systemctl: $msg; run git-secret-guard install --with-timer"
        bad=1
    fi
    if [ "$bad" -eq 0 ]; then
        doctor_machine_line ok "timer: $GSG_TIMER_UNIT and $GSG_SERVICE_UNIT are in $GSG_UNIT_DIR; systemctl $bin"
    fi
}

doctor_check_hooks_path() {
    local i found=0
    lifecycle_read_hooks_path || return 1
    for i in "${!GSG_HP_OWN[@]}"; do
        doctor_machine_line PROBLEM "core.hooksPath: [${GSG_HP_OWN[$i]}] is still set in ${GSG_HP_FILE#file:}; remove it (git config --global --unset-all core.hooksPath)"
        found=1
    done
    for i in "${!GSG_HP_FOREIGN_FILE[@]}"; do
        doctor_machine_line PROBLEM "core.hooksPath: [${GSG_HP_FOREIGN_VALUE[$i]}] is set in ${GSG_HP_FOREIGN_FILE[$i]}; remove it there"
        found=1
    done
    if [ "$found" -eq 0 ]; then doctor_machine_line ok "core.hooksPath: no global value"; fi
}

doctor_check_git() {
    local i cand ver
    install_collect_gits
    for i in "${!GSG_GIT_CANDIDATES[@]}"; do
        cand="${GSG_GIT_CANDIDATES[$i]}"
        ver="$(install_git_version "$cand")" || ver=""
        if [ -n "$ver" ] && install_git_is_new_enough "$cand"; then
            doctor_machine_line ok "git: $cand $ver"
        else
            doctor_machine_line WARNING "git: $cand is git ${ver:-of unknown version}; it ignores config-based hooks without any message, so commits made with it are NOT scanned"
        fi
    done
}

doctor_summary() {
    printf 'summary: %s repos, %s covered\n' "$DR_REPO_TOTAL" "$DR_REPO_COVERED"
    if [ "$DR_WARNINGS" -gt 0 ]; then
        printf 'warnings: %s (listed above, they do not change the exit status)\n' "$DR_WARNINGS"
    fi
}

# ^ invariant exit 0 = no PROBLEM line, 1 = at least one, 2 = doctor could not run; WARNING and info never change the status
doctor_run() {
    paths_init || return 2
    lifecycle_note_global_config
    doctor_require_git || return 2
    doctor_resolve_roots "$@" || return 2
    doctor_start || return 2
    printf 'machine:\n'
    doctor_check_state
    doctor_check_hook_config
    doctor_check_tools
    doctor_check_timer
    doctor_check_hooks_path || return 2
    doctor_check_git
    doctor_repos || return 2
    doctor_summary
    [ "$DR_PROBLEMS" -eq 0 ]
}
