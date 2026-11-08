# shellcheck shell=bash disable=SC2153

status_line() { printf '%s: %s\n' "$1" "$2"; }

# ^ invariant sets STATUS_PROBLEMS += 1 for every line printed with MISMATCH or MISSING => the exit code is 1 exactly when one was printed
status_problem() {
    STATUS_PROBLEMS=$((STATUS_PROBLEMS + 1))
}

# ^ invariant names come from GSG_HOOK_LIBS and GSG_HOOK_FILES (lib/common.sh), the lists the hook loads from; a readable file is enough, none is sourced here
# ^ coupled the text repeats the hook's own block, cannot load <path> and nothing was scanned; test:test_the_hook_loads_exactly_the_libraries_in_the_shared_list
status_hook_files() {
    local rel path why bad=0 total=0
    if ! hook_libs_listed; then
        status_line "hook libraries" "MISMATCH (GSG_HOOK_LIBS in $GSG_SHARE/lib/common.sh is unset or empty; the hook blocks every commit: nothing is scanned)"
        status_problem
        bad=1
    fi
    for rel in common.sh "${GSG_HOOK_LIBS[@]}" "${GSG_HOOK_FILES[@]}"; do
        total=$((total + 1))
        path="$GSG_SHARE/lib/$rel"
        if [ -f "$path" ] && [ -r "$path" ]; then continue; fi
        why="not a readable file"
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then why=missing; fi
        status_line "hook libraries" "MISMATCH (cannot read $path: $why; the hook blocks every commit: nothing is scanned)"
        status_problem
        bad=$((bad + 1))
    done
    if [ "$bad" -eq 0 ]; then status_line "hook libraries" "$total files present and readable"; fi
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

STATUS_TMP=""

# ^ invariant rm -rf only on the absolute mktemp directory this run made; runs from the EXIT trap of the subshell in status_hook_listing
status_cleanup() {
    if [ -n "$STATUS_TMP" ] && [ "${STATUS_TMP#/}" != "$STATUS_TMP" ] && ! rm -rf -- "$STATUS_TMP"; then
        printf '%s: cannot remove %s\n' "$GSG_NAME" "$STATUS_TMP" >&2
    fi
}

# ^ security the message is first_message output (control characters replaced, cut at 200) => no escape sequence reaches the terminal
status_hook_failed() {
    status_line "hook list" "MISMATCH (git $1 failed with exit $2${3:+: $3}; commits may be blocked or unscanned until it works)"
}

# ^ invariant location only => git already said the hook is off or failed; the scan names key, scope, file and advice, and never decides
# ^ invariant a failing scan or an empty result is reported plainly and changes nothing; an enabled value is printed, never a command or event
status_hook_locate() {
    local want="$1" i adv origin value found=0
    if ! hp_hook_enabled_scan; then
        status_line "hook enabled" "git reports the hook disabled; the setting could not be located (the git config could not be read; find it with: git config --show-origin --get-all $want)"
        return 0
    fi
    for i in "${!HP_EN_KIND[@]}"; do
        if [ "${HP_EN_KEY[$i]}" != "$want" ] && [ "${HP_EN_KIND[$i]}" != valueless ]; then continue; fi
        hp_hook_enabled_advice "$i"
        adv="$REPLY"
        origin="${HP_EN_ORIGIN[$i]#file:}"
        origin="${origin//[^[:print:]]/?}"
        value="${HP_EN_VALUE[$i]//[^[:print:]]/?}"
        trunc_text "$value" 40
        value="$REPLY"
        found=1
        case "${HP_EN_KIND[$i]}" in
            valueless) status_line "hook enabled" "${HP_EN_KEY[$i]} has no value in the ${HP_EN_SCOPE[$i]} config ($origin); git commands fail until it is removed; $adv" ;;
            unjudged) status_line "hook enabled" "git reports the hook disabled; the setting could not be located (the boolean probe failed: $value)" ;;
            *) status_line "hook enabled" "${HP_EN_KEY[$i]}=$value in the ${HP_EN_SCOPE[$i]} config ($origin) switches the hook off, commits are not scanned; $adv" ;;
        esac
    done
    if [ "$found" -eq 0 ] && [ "$want" != valueless ]; then
        status_line "hook enabled" "git reports the hook disabled; the setting could not be located (find it with: git config --show-origin --get-all $want)"
    fi
}

# ^ external a conditional include (includeIf gitdir, onbranch, hasconfig) never matches the throwaway repository => doctor sees such settings, status cannot
# ^ security only the file holding the includeIf is named, never its condition or path; informational, never a problem
status_conditional_includes() {
    local i scope file seen=" " list=""
    hp_records -C / config --show-scope --show-origin -z --get-regexp '^includeif\..*\.path$'
    if [ "$?" -gt 1 ]; then return 0; fi
    for ((i = 0; i + 2 < ${#GSG_HP_OUT[@]}; i += 3)); do
        scope="${GSG_HP_OUT[i]}"
        file="${GSG_HP_OUT[i + 1]#file:}"
        file="${file//[^[:print:]]/?}"
        if [ "$scope" != global ] && [ "$scope" != system ]; then continue; fi
        if [[ $seen == *" $file "* ]]; then continue; fi
        seen+="$file "
        list+="${list:+, }$file ($scope)"
    done
    if [ -n "$list" ]; then
        status_line "conditional includes" "$list holds an includeIf; settings reached through one (gitdir, onbranch, hasconfig) are not seen here, only per repository by $GSG_NAME doctor (informational)"
    fi
}

# ^ invariant rc 0 = git lists the hook as running before commits; rc 1 = a MISMATCH line was printed; runs in a subshell, see status_hook_listing
# ^ order traps before mktemp => an interrupt leaves no directory behind; the probe unsets the caller's repository variables in its own subshell
status_hook_ask() {
    local res kind step rc msg
    trap status_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    STATUS_TMP="$(mktemp -d)" || {
        status_line "hook list" "MISMATCH (cannot create a temp directory to ask git about the hook; check TMPDIR; commits may be unscanned)"
        return 1
    }
    hooklist_bind_timeout
    res="$(hooklist_probe_line "$STATUS_TMP")"
    IFS=$'\t' read -r kind step rc msg <<<"$res"
    if [ "$kind" != ok ]; then
        if [ "$kind" != fail ]; then
            status_hook_failed "hook probe" "?" "no answer"
            return 1
        fi
        status_hook_failed "$step" "$rc" "$msg"
        status_hook_locate valueless
        return 1
    fi
    case "$step" in
        effective) return 0 ;;
        disabled)
            status_line "hook enabled" "MISMATCH (git hook list pre-commit shows git-secret-guard as disabled by hook.git-secret-guard.enabled, so commits are not scanned)"
            status_hook_locate hook.git-secret-guard.enabled
            ;;
        event-disabled)
            status_line "hook enabled" "MISMATCH (git hook list pre-commit shows git-secret-guard as event-disabled by hook.pre-commit.enabled, so commits are not scanned)"
            status_hook_locate hook.pre-commit.enabled
            ;;
        *)
            status_line "hook list" "MISMATCH (git-secret-guard is not in git hook list pre-commit, so commits are not scanned; run $GSG_NAME install)"
            ;;
    esac
    return 1
}

# ^ why git hook list in a throwaway bare repository, not config reads => git alone decides what an enabled value means
# ^ external git 2.56 reads false no off 0 00 0k 0x0 -0 and empty as off; a bad value after false stays off; a value-less key fails init
# ^ external hook.pre-commit.enabled=false stops every pre-commit config hook (git hook list says event-disabled); doc:docs/doctor.md
status_hook_listing() {
    local rc
    (status_hook_ask)
    rc=$?
    # ^ external bash counts a child with an INT trap and exit 130 as having survived the signal => the parent follows or prints on
    if [ "$rc" -gt 128 ]; then exit "$rc"; fi
    if [ "$rc" -ne 0 ]; then status_problem; fi
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

# ^ invariant macOS only; doctor's two checks (tool_unusable, brew_bash_ok asks the binary for its version), stdin closed
# ^ hazard BASH_BIN naming a non-bash program with exit 0 => git counts the hook as passed, the commit lands unscanned; doc:docs/platforms.md
status_bash() {
    local msg why shown="${BASH_BIN:-}"
    if msg="$(tool_unusable bash "$shown")"; then
        msg="${msg//[[:cntrl:]]/?}"
        # ^ external measured with a bash 5 on PATH, an unset or relative BASH_BIN still starts the hook; the reasons say what bash 3.2 would do
        case "$shown" in
            "") why="the hook command is the bare hook path, so a git client with /bin/bash 3.2 first on PATH runs it under bash 3.2 and the hook blocks every commit" ;;
            /*) why="git cannot start the hook with it and the commit fails" ;;
            *) why="git runs whichever bash its PATH finds first, and under bash 3.2 the hook blocks every commit" ;;
        esac
        status_line bash "MISMATCH ($msg; $why; run: $GSG_NAME install)"
        status_problem
    elif ! brew_bash_ok "$shown" </dev/null; then
        shown="${shown//[[:cntrl:]]/?}"
        status_line bash "MISMATCH ($shown does not report bash $BREW_BASH_MIN_MAJOR.$BREW_BASH_MIN_MINOR or newer; an old bash makes the hook block every commit and a program that is not bash can let commits pass unscanned; run: $GSG_NAME install)"
        status_problem
    else
        status_line bash "$shown"
    fi
}

# ^ invariant the rule is gnubin_dir_unusable (lib/common.sh), the hook's own; an unset GNUBIN_DIR prints nothing and is no problem
status_gnubin() {
    local shown="${GNUBIN_DIR:-}"
    if [ -z "$shown" ]; then return 0; fi
    shown="${shown//[[:cntrl:]]/?}"
    if gnubin_dir_unusable; then
        status_line GNUBIN_DIR "MISMATCH (GNUBIN_DIR in the settings file is not an absolute directory ($shown); the hook blocks every commit: nothing is scanned; run: $GSG_NAME install)"
        status_problem
    else
        status_line GNUBIN_DIR "$shown"
    fi
}

# ^ invariant a tool without a version pin is usable (absolute, executable file) or gets a MISSING line and a problem
status_plain_tool() {
    if tool_unusable "$1" "$2" >/dev/null; then
        status_line "$1" "$2 (MISSING or not executable)"
        status_problem
    else
        status_line "$1" "$2"
    fi
}

# ^ invariant judged like doctor_check_agent does (tool_unusable, never run) and only when the state says a timer is installed
status_launchctl() {
    if [ "$ST_TIMER" != yes ]; then return 0; fi
    status_plain_tool launchctl "$(settings_tool_bin launchctl)"
}

# ^ invariant GNUBIN_DIR is judged on every platform, the hook blocks on it everywhere; BASH_BIN and LAUNCHCTL_BIN are macOS-only lines
# ^ order bash, GNUBIN_DIR, launchctl, after status_tools loaded the settings
status_settings_keys() {
    if brew_is_macos; then status_bash; fi
    status_gnubin
    if brew_is_macos; then status_launchctl; fi
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
        status_plain_tool "$tool" "$bin"
    done
    status_settings_keys
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
        return 1
    elif install_git_is_new_enough "$GSG_GIT"; then
        status_line "git in use" "$(gitup_display_path "$GSG_GIT") (git $ver)"
    else
        status_line "git in use" "$(gitup_display_path "$GSG_GIT") (git $ver) MISMATCH: config hooks need git >= 2.54, so commits are not scanned; run: $GSG_NAME install --upgrade-git"
        status_problem
        return 1
    fi
}

status_run() {
    STATUS_PROBLEMS=0
    paths_init || return 1
    lifecycle_note_global_config
    lifecycle_require_git || return 1
    state_read || return 1
    if [ -z "${GITUP_SYSTEM_PATH:-}" ]; then gitup_paths || return 1; fi
    local git_ok=0
    status_git || git_ok=1
    if [ "$ST_EXISTS" -ne 1 ]; then
        printf '%s: not installed (no state file at %s)\n' "$GSG_NAME" "$GSG_STATE_FILE"
        if gitup_system_git_state && [ "$GITUP_TK_STATE" != none ]; then status_system_git; fi
        status_unfinished_copy
        return 1
    fi
    status_line "installed version" "$ST_VERSION"
    status_line "share dir" "$GSG_SHARE"
    status_hook_command
    status_hook_files
    status_config
    if [ "$git_ok" -eq 0 ]; then
        status_hook_listing
        status_conditional_includes
    fi
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
