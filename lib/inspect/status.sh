# shellcheck shell=bash disable=SC2153

STATUS_PROBLEMS=0
STATUS_WARNINGS=0
STATUS_SECTION=""

# ^ invariant the header is printed with the first line of its section => a section without lines shows no header
status_section() { STATUS_SECTION="$1"; }

# ^ invariant args = level (PROBLEM, WARNING, ok, info), label, text; every status line goes through here => each PROBLEM is counted once
# ^ invariant STATUS_PROBLEMS > 0 exactly when a PROBLEM line was printed => the exit code is 1 exactly when one was; a WARNING never changes it
# ^ invariant one printf serves both modes; ui_mark gives the padded tag in plain mode and the icon in terminal mode
status_line() {
    case "$1" in
        PROBLEM) STATUS_PROBLEMS=$((STATUS_PROBLEMS + 1)) ;;
        WARNING) STATUS_WARNINGS=$((STATUS_WARNINGS + 1)) ;;
    esac
    if [ -n "$STATUS_SECTION" ]; then
        printf '%s:\n' "$STATUS_SECTION"
        STATUS_SECTION=""
    fi
    ui_mark 1 "$1"
    printf '  %s %s: %s\n' "$REPLY" "$2" "$3"
}

# ^ invariant the last line of status holds the counts of PROBLEM and WARNING lines, with the icon of the worst level in front in terminal mode
status_summary() {
    local p=problems w=warnings
    if [ "$STATUS_PROBLEMS" -eq 1 ]; then p=problem; fi
    if [ "$STATUS_WARNINGS" -eq 1 ]; then w=warning; fi
    ui_worst "$STATUS_PROBLEMS" "$STATUS_WARNINGS"
    ui_prefix 1 "$REPLY"
    printf '%ssummary: %s %s, %s %s\n' "$REPLY" "$STATUS_PROBLEMS" "$p" "$STATUS_WARNINGS" "$w"
}

# ^ invariant names come from GSG_HOOK_LIBS and GSG_HOOK_FILES (core/common.sh), the lists the hook loads from; a readable file is enough, none is sourced here
# ^ coupled the text repeats the hook's own block, cannot load <path> and nothing was scanned; test:test_the_hook_loads_exactly_the_libraries_in_the_shared_list
status_hook_files() {
    local rel path why bad=0 total=0 other="" cli
    # ^ why the share's own VERSION file, not the state; a CLI newer than the installed share lists libraries the installed hook never loads
    cli="$(<"$GSG_ROOT/VERSION")" || cli=""
    if [ -r "$GSG_SHARE/VERSION" ]; then other="$(<"$GSG_SHARE/VERSION")" || other=""; else other="${ST_VERSION:-}"; fi
    if [ -z "$cli" ] || [ "$other" = "$cli" ]; then other=""; fi
    if ! hook_libs_listed; then
        status_line PROBLEM "hook libraries" "MISMATCH (GSG_HOOK_LIBS in $GSG_SHARE/lib/core/common.sh is unset or empty; the hook blocks every commit: nothing is scanned)"
        bad=1
    fi
    for rel in core/common.sh "${GSG_HOOK_LIBS[@]}" "${GSG_HOOK_FILES[@]}"; do
        total=$((total + 1))
        path="$GSG_SHARE/lib/$rel"
        if [ -f "$path" ] && [ -r "$path" ]; then continue; fi
        why="not a readable file"
        if [ ! -e "$path" ] && [ ! -L "$path" ]; then why=missing; fi
        bad=$((bad + 1))
        if [ -n "$other" ]; then continue; fi
        status_line PROBLEM "hook libraries" "MISMATCH (cannot read $path: $why; the hook blocks every commit: nothing is scanned)"
    done
    if [ "$bad" -gt 0 ] && [ -n "$other" ]; then
        status_line PROBLEM "hook libraries" "MISMATCH (the installed hook is $GSG_NAME $other, this CLI is $cli; run $GSG_NAME install)"
    fi
    if [ "$bad" -eq 0 ]; then status_line ok "hook libraries" "$total files present and readable"; fi
}

status_config() {
    local events commands want_cmd diff=""
    # ^ why a PROBLEM line, not a silent return; a relative recorded bash is refused by hook_command_text and the config cannot be judged
    want_cmd="$(hook_command_text "$GSG_SHARE" "$(share_recorded_bash "$GSG_SHARE")" 2>/dev/null)" || {
        status_line PROBLEM "global config" "MISMATCH (the wanted command cannot be built: the recorded bash is not an absolute path; run: $GSG_NAME install)"
        return 0
    }
    events="$("$GSG_GIT" config --global --get-all hook.git-secret-guard.event 2>/dev/null | tr '\n' ' ')"
    commands="$("$GSG_GIT" config --global --get-all hook.git-secret-guard.command 2>/dev/null | tr '\n' ' ')"
    # ^ why either order, not only the order install writes; git lists both events in any order, a hand edit swapping them is no fault
    if [ "$events" != "pre-commit commit-msg " ] && [ "$events" != "commit-msg pre-commit " ]; then
        diff="event=[${events% }] want [pre-commit commit-msg]"
    fi
    if [ "$commands" != "$want_cmd " ]; then
        diff+="${diff:+; }command=[${commands% }] want [$want_cmd]"
    fi
    if [ -z "$diff" ]; then
        status_line ok "global config" "matches (hook.git-secret-guard.event=pre-commit and commit-msg, .command=$want_cmd)"
    else
        status_line PROBLEM "global config" "MISMATCH ($diff)"
    fi
}

status_hook_command() {
    local cmd="$GSG_SHARE/hooks/secret-scan"
    if [ -f "$cmd" ] && [ -x "$cmd" ]; then
        status_line ok "hook command" "$cmd"
    else
        status_line PROBLEM "hook command" "$cmd (MISSING or not executable)"
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
    status_line PROBLEM "hook list" "MISMATCH (git $1 failed with exit $2${3:+: $3}; commits may be blocked or unscanned until it works)"
}

# ^ invariant location only => git already said the hook is off or failed; the scan names key, scope, file and advice, and never decides
# ^ invariant a failing scan or an empty result is reported plainly and changes nothing; an enabled value is printed, never a command or event
status_hook_locate() {
    local want="$1" i adv origin value found=0
    if ! hp_hook_enabled_scan; then
        status_line info "hook enabled" "git reports the hook disabled; the setting could not be located (the git config could not be read; find it with: git config --show-origin --get-all $want)"
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
            valueless) status_line info "hook enabled" "${HP_EN_KEY[$i]} has no value in the ${HP_EN_SCOPE[$i]} config ($origin); git commands fail until it is removed; $adv" ;;
            unjudged) status_line info "hook enabled" "git reports the hook disabled; the setting could not be located (the boolean probe failed: $value)" ;;
            *)
                if [ "${HP_EN_KEY[$i]}" = hook.commit-msg.enabled ]; then
                    status_line info "hook enabled" "${HP_EN_KEY[$i]}=$value in the ${HP_EN_SCOPE[$i]} config ($origin) disables the commit-msg event: commit messages are not scanned (lines still are); $adv"
                else
                    status_line info "hook enabled" "${HP_EN_KEY[$i]}=$value in the ${HP_EN_SCOPE[$i]} config ($origin) switches the hook off, commits are not scanned; $adv"
                fi
                ;;
        esac
    done
    if [ "$found" -eq 0 ] && [ "$want" != valueless ]; then
        status_line info "hook enabled" "git reports the hook disabled; the setting could not be located (find it with: git config --show-origin --get-all $want)"
    fi
}

# ^ external a conditional include (includeIf gitdir, onbranch, hasconfig) never matches the throwaway repository => doctor sees such settings, status cannot
# ^ security only the file holding the includeIf is named, never its condition or path; informational, never a problem
status_conditional_includes() {
    local i scope file seen=" " list=""
    hp_records -C / config --show-scope --show-origin -z --get-regexp '^includeif\..*\.path$'
    if [ "$?" -gt 1 ]; then
        status_line info "conditional includes" "the git config could not be read for includeIf settings; they are not checked here (informational)"
        return 0
    fi
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
        status_line info "conditional includes" "$list holds an includeIf; settings reached through one (gitdir, onbranch, hasconfig) are not seen here, only per repository by $GSG_NAME doctor (informational)"
    fi
}

# ^ invariant rc 0 = git lists the hook as running; otherwise rc = the number of PROBLEM lines printed (1 or 2); runs in a subshell, see status_hook_listing
# ^ order traps before mktemp => an interrupt leaves no directory behind; the probe unsets the caller's repository variables in its own subshell
status_hook_ask() {
    local res kind step rc msg lines_status msg_status bad=0
    trap status_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    STATUS_TMP="$(mktemp -d)" || {
        status_line PROBLEM "hook list" "MISMATCH (cannot create a temp directory to ask git about the hook; check TMPDIR; commits may be unscanned)"
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
    # ^ invariant on ok the line holds two statuses, pre-commit first and commit-msg second (hooklist_probe_line); read here as step and rc
    lines_status="$step" msg_status="$rc"
    status_hook_event pre-commit "$lines_status" "commits are not scanned" || bad=$((bad + 1))
    # ^ why skip a repeated disable, not print it twice; hook.git-secret-guard.enabled=false switches both events off and one line says so
    if ! { [ "$lines_status" = disabled ] && [ "$msg_status" = disabled ]; }; then
        status_hook_event commit-msg "$msg_status" "commit messages are not scanned" || bad=$((bad + 1))
    fi
    return "$bad"
}

# ^ invariant args = event, its status from git's listing, what it means for the user; prints a MISMATCH line and locates the setting; rc 1 = not effective
status_hook_event() {
    local event="$1" listed="$2" meaning="$3"
    case "$listed" in
        effective) return 0 ;;
        disabled)
            status_line PROBLEM "hook enabled" "MISMATCH (git hook list $event shows git-secret-guard as disabled by hook.git-secret-guard.enabled, so $meaning)"
            status_hook_locate hook.git-secret-guard.enabled
            ;;
        event-disabled)
            status_line PROBLEM "hook enabled" "MISMATCH (git hook list $event shows git-secret-guard as event-disabled by hook.$event.enabled, so $meaning)"
            status_hook_locate "hook.$event.enabled"
            ;;
        *)
            status_line PROBLEM "hook list" "MISMATCH (git-secret-guard is not in git hook list $event, so $meaning; run $GSG_NAME install)"
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
    # ^ invariant the subshell cannot count or track a header; its status is its number of PROBLEM lines and the parent adds it
    # ^ invariant status_hook_ask returns 0, 1 or 2; any other status is no count of lines => one PROBLEM line says so, status_line counts it once
    if [ "$rc" -gt 2 ]; then
        status_line PROBLEM "hook list" "the check ended with exit $rc"
        return 0
    fi
    STATUS_PROBLEMS=$((STATUS_PROBLEMS + rc))
    if [ "$rc" -gt 0 ]; then STATUS_SECTION=""; fi
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
    status_line info "core.hooksPath (effective)" "${list:-unset}"
}

status_tool() {
    local name="$1" bin="$2" pinned="$3"
    if tool_unusable "$name" "$bin" >/dev/null; then
        status_line PROBLEM "$name" "$bin (MISSING or not executable)"
        return 0
    fi
    if tools_probe_version "$bin" "$pinned" "$TIMEOUT_BIN"; then
        status_line ok "$name" "$bin $TOOL_FOUND (pinned $pinned)"
    else
        status_line PROBLEM "$name" "$bin $TOOL_FOUND (pinned $pinned) MISMATCH"
    fi
}

# ^ invariant every platform; doctor's two checks (tool_unusable, brew_bash_ok asks the binary for its version), stdin closed
# ^ hazard BASH_BIN naming a non-bash program with exit 0 => git counts the hook as passed, the commit lands unscanned; doc:docs/platforms.md
status_bash() {
    local msg why shown="${BASH_BIN:-}"
    if msg="$(tool_unusable bash "$shown")"; then
        msg="${msg//[[:cntrl:]]/?}"
        # ^ why the unset reason names the shebang, not a platform; an install from before the recorded bash has the bare hook path everywhere (#28, #31)
        case "$shown" in
            "") why="the hook command is the bare hook path, so the bash the script's shebang finds first on PATH runs the hook (an old bash blocks every commit, a stand-in or a program that is not bash can let commits pass unscanned)" ;;
            /*) why="the hook command stops with its own message and the commit is blocked: nothing is scanned" ;;
            *) why="the hook command cannot be written with it (a relative bash is refused), so install and doctor fail until it is fixed" ;;
        esac
        status_line PROBLEM bash "MISMATCH ($msg; $why; run: $GSG_NAME install)"
    elif ! brew_bash_ok "$shown" </dev/null; then
        shown="${shown//[[:cntrl:]]/?}"
        status_line PROBLEM bash "MISMATCH ($shown does not report bash $BREW_BASH_MIN_MAJOR.$BREW_BASH_MIN_MINOR or newer; an old bash makes the hook block every commit and a program that is not bash can let commits pass unscanned; run: $GSG_NAME install)"
    else
        status_line ok bash "$shown"
    fi
}

# ^ invariant the rule is gnubin_dir_unusable (lib/core/common.sh), the hook's own; an unset GNUBIN_DIR prints nothing and is no problem
status_gnubin() {
    local shown="${GNUBIN_DIR:-}"
    if [ -z "$shown" ]; then return 0; fi
    shown="${shown//[[:cntrl:]]/?}"
    if gnubin_dir_unusable; then
        status_line PROBLEM GNUBIN_DIR "MISMATCH (GNUBIN_DIR in the settings file is not an absolute directory ($shown); the hook blocks every commit: nothing is scanned; run: $GSG_NAME install)"
    else
        status_line ok GNUBIN_DIR "$shown"
    fi
}

# ^ invariant the verdict is rule_file_hash_check (lib/core/common.sh), the hook's own; an unreadable file prints nothing here, the hook libraries line says so
status_rule_file() {
    local file="$GSG_SHARE/lib/scan/betterleaks-rule.toml" why rc
    if [ ! -r "$file" ]; then return 0; fi
    why="$(rule_file_hash_check "$file")"
    rc=$?
    file="${file//[[:cntrl:]]/?}"
    case "$rc" in
        0) status_line ok "rule file" "$file matches the SHA-256 install recorded" ;;
        2) status_line PROBLEM "rule file" "MISMATCH (no SHA-256 of $file is recorded in the settings file, an install from before this check, so an edit of it is not noticed; run: $GSG_NAME install)" ;;
        *) status_line PROBLEM "rule file" "MISMATCH ($file $why; the hook blocks every commit: nothing is scanned; reinstall from a checkout or a release: bin/$GSG_NAME install)" ;;
    esac
}

# ^ invariant a tool without a version pin is usable (absolute, executable file) or gets a MISSING line and a problem
status_plain_tool() {
    if tool_unusable "$1" "$2" >/dev/null; then
        status_line PROBLEM "$1" "$2 (MISSING or not executable)"
    else
        status_line ok "$1" "$2"
    fi
}

# ^ invariant judged like doctor_check_agent does (tool_unusable, never run) and only when the state says a timer is installed
status_launchctl() {
    if [ "$ST_TIMER" != yes ]; then return 0; fi
    status_plain_tool launchctl "$(settings_tool_bin launchctl)"
}

# ^ invariant BASH_BIN and GNUBIN_DIR are judged on every platform, the hook command and the hook block on them everywhere; LAUNCHCTL_BIN is a macOS-only line
# ^ order bash, GNUBIN_DIR, launchctl, after status_tools loaded the settings
status_settings_keys() {
    status_bash
    status_gnubin
    status_rule_file
    if brew_is_macos; then status_launchctl; fi
}

status_tools() {
    local tool plat row bin
    status_section tools
    if ! load_settings "$GSG_SHARE/settings" 2>/dev/null; then
        status_line PROBLEM "settings" "$GSG_SHARE/settings (MISSING or unreadable)"
        return 0
    fi
    if tool_unusable timeout "${TIMEOUT_BIN:-}" >/dev/null; then
        status_line PROBLEM "timeout" "${TIMEOUT_BIN:-} (MISSING or not executable)"
        return 0
    fi
    gsg_os_fill && gsg_arch_fill || return 1
    GSG_OS="$GSG_UNAME_S"
    GSG_ARCH="$GSG_UNAME_M"
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
        none | active) status_line info "system git takeover" "$GITUP_TK_TEXT" ;;
        *) status_line PROBLEM "system git takeover" "MISMATCH $GITUP_TK_TEXT" ;;
    esac
}

# ^ invariant an interrupted source copy (MANIFEST.partial) is shown with its next step; a WARNING, never a problem
status_unfinished_copy() {
    if gitup_source_unfinished_copy; then status_line WARNING "git build" "$REPLY"; fi
}

# ^ invariant names the first git on PATH and its version on every run; older than 2.54 (or unreadable) is a problem => its config hooks never fire
# ^ coupled a second old git behind the first is not judged here, doctor reports it
status_git() {
    local ver
    if ! ver="$(install_git_version "$GSG_GIT")"; then
        status_line PROBLEM "git in use" "$(gitup_display_path "$GSG_GIT") (version unreadable; if it is older than 2.54 commits are not scanned) MISMATCH"
        return 1
    elif install_git_is_new_enough "$GSG_GIT"; then
        status_line ok "git in use" "$(gitup_display_path "$GSG_GIT") (git $ver)"
    else
        status_line PROBLEM "git in use" "$(gitup_display_path "$GSG_GIT") (git $ver) MISMATCH: config hooks need git >= 2.54, so commits are not scanned; run: $GSG_NAME install --upgrade-git"
        return 1
    fi
}

# ^ invariant the install section holds the state's own record of the installation, the share and the hook files; the git section follows it
status_install_lines() {
    local entry asides=""
    status_section install
    status_line info "installed version" "$ST_VERSION"
    status_line info "share dir" "$GSG_SHARE"
    status_hook_command
    status_hook_files
    status_config
    if [ "$ST_PREV_SET" = yes ]; then
        status_line info "previous core.hooksPath" "$ST_PREV"
    else
        status_line info "previous core.hooksPath" "unset"
    fi
    status_line info "hooks backup" "${ST_BACKUP:-none}"
    status_line info "tools installed by us" "${ST_TOOLS:-none}"
    for entry in $ST_REPLACED; do
        asides+="${asides:+ }${entry%:*}"
    done
    status_line info "originals moved aside" "${asides:-none}"
    if ! install_path_has_dir "$GSG_BIN_DIR"; then status_line info "CLI folder" "$(install_path_missing_text)"; fi
}

# ^ invariant arg = 0 when the git in use passed its check, only a passed check asks git about the hook; rc 1 = reading the git config failed
status_git_lines() {
    local rc=0
    if [ "$1" -eq 0 ]; then
        status_hook_listing
        status_conditional_includes
    fi
    if status_git_lists_scopes; then
        status_hooks_path || rc=1
    else
        status_line info "core.hooksPath (effective)" "not read (the git in use cannot list config scopes)"
    fi
    status_system_git
    status_unfinished_copy
    return "$rc"
}

# ^ invariant the order is install, git, tools, clients, auto-update, summary; the git in use is checked first, its line is the first one of the git section
# ^ invariant without a state file the install section is one PROBLEM line, the git section follows, the tools and clients are not judged
# ^ invariant a section read to a failed end prints a PROBLEM line and the run goes on to the summary => exit 1 still means a PROBLEM line
status_run() {
    local git_ok=0
    STATUS_PROBLEMS=0 STATUS_WARNINGS=0 STATUS_SECTION=""
    paths_init || return 1
    lifecycle_note_global_config
    lifecycle_require_git || return 1
    state_read || return 1
    if [ -z "${GITUP_SYSTEM_PATH:-}" ]; then gitup_paths || return 1; fi
    if [ "$ST_EXISTS" -ne 1 ]; then
        status_section install
        status_line PROBLEM installed "not installed (no state file at $GSG_STATE_FILE); run $GSG_NAME install"
        status_section git
        status_git || true
        if gitup_system_git_state && [ "$GITUP_TK_STATE" != none ]; then status_system_git; fi
        status_unfinished_copy
        status_summary
        return 1
    fi
    status_install_lines
    status_section git
    status_git || git_ok=1
    status_git_lines "$git_ok" || status_line PROBLEM git "the git config could not be read; the lines above are incomplete"
    status_tools || status_line PROBLEM tools "a tool setting could not be read; the lines above are incomplete"
    status_section clients
    smartgit_status_lines
    desktop_git_status_lines || status_line PROBLEM clients "the GitHub Desktop state could not be read; the lines above are incomplete"
    status_section auto-update
    autoupdate_status_lines
    status_summary
    [ "$STATUS_PROBLEMS" -eq 0 ]
}
