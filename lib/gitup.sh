# shellcheck shell=bash disable=SC2034,SC2153
# ^ coupled install-time only; the CLI loads it after lib/install.sh and the hook never does (test:test_the_hook_never_loads_the_install_time_libraries)
# ^ coupled the contract a module implements is in CONTRIBUTING.md "Adding an OS module"; test:test_every_registered_module_implements_the_contract

GITUP_CLASSES=(rpm ubuntu debian macos windows wsl other)
GITUP_REQUIRED_FNS=(plan apply)
GITUP_TAKEOVER_FNS=(takeover_supported takeover_plan takeover_apply takeover_restore takeover_status)

# ^ invariant what the git upgrade changed in this run, "" = nothing; refusal texts quote it through brew_unchanged_text
GITUP_CHANGED=""
# ^ invariant 1 = git is missing or older than 2.54 and the class has a module; install_run offers the upgrade after its other refusable checks
GITUP_PENDING=0
GITUP_SELECTED=0
GITUP_CLASS="" GITUP_MODULE=""
# ^ invariant plan sets GITUP_ROUTE (and GITUP_FOUND_GIT for path-fix), apply sets GITUP_NEXT on rc 2, a takeover plan sets GITUP_REASON on rc 1 and 2
GITUP_ROUTE="" GITUP_FOUND_GIT="" GITUP_NEXT="" GITUP_REASON=""
GITUP_PRIV_CMDS=()
# ^ invariant 0 = commands depend on checks made between them (a key, a version floor); with no way to elevate the user is told to run install as root
GITUP_PRIV_BYHAND=1
GITUP_SUDO=""
GITUP_UPGRADE_FLAG=0 GITUP_TAKEOVER_FLAG=0
GITUP_PLAN_REFUSED=0

# ^ invariant sets REPLY = rpm, ubuntu, debian, macos, windows, wsl or other; uname decides macOS and Windows, os-release (data, never sourced) the Linux class
# ^ invariant wsl = the kernel files say WSL and the distribution inside is rpm, ubuntu or debian; any other WSL distribution stays other, with today's refusal
# ^ coupled the wsl module wraps the module of the inner class (lib/gitup_wsl.sh); a module needing its own class reads gitup_inner_class
gitup_os_class() {
    local family
    if tools_is_windows; then
        REPLY=windows
        return 0
    fi
    if brew_is_macos; then
        REPLY=macos
        return 0
    fi
    install_os_family
    case "$REPLY" in
        rpm | ubuntu | debian) ;;
        *) REPLY=other ;;
    esac
    family="$REPLY"
    if [ "$family" != other ] && wsl_is; then family=wsl; fi
    REPLY="$family"
}

# ^ invariant a wrapper module (wsl) sets GITUP_INNER_CLASS before it delegates; gitup_inner_class sets REPLY to it, else to GITUP_CLASS
GITUP_INNER_CLASS=""
gitup_inner_class() { REPLY="${GITUP_INNER_CLASS:-$GITUP_CLASS}"; }

# ^ invariant the one table of modules; sets REPLY = the module name of a class, "" = no module yet (today's refusal and hint); rc 1 = not a class
# ^ coupled a module is lib/gitup_<module>.sh plus one line here; a comment line between class lines => adjacent edits conflict in git merge
# ^ see test:test_branches_that_each_take_one_reserved_registry_line_merge_without_conflicts
gitup_registry() {
    REPLY=""
    case "$1" in
        rpm) REPLY=rpm ;;
        # ^ see doc:CONTRIBUTING.md
        ubuntu) REPLY=apt ;;
        # ^ see doc:CONTRIBUTING.md
        debian) REPLY=apt ;;
        # ^ see doc:CONTRIBUTING.md
        macos) REPLY=macos ;;
        # ^ see doc:CONTRIBUTING.md
        windows) REPLY=windows ;;
        # ^ see doc:CONTRIBUTING.md
        wsl) REPLY=wsl ;;
        # ^ see doc:CONTRIBUTING.md
        other) REPLY="" ;;
        *) return 1 ;;
    esac
}

# ^ invariant true when dotted version $1 is at least dotted version $2; a missing component counts as 0, a non-numeric one is an error (rc 2)
gitup_version_at_least() {
    local -a have want
    local i n
    IFS=. read -r -a have <<<"$1"
    IFS=. read -r -a want <<<"$2"
    n="${#have[@]}"
    if [ "${#want[@]}" -gt "$n" ]; then n="${#want[@]}"; fi
    for ((i = 0; i < n; i++)); do
        if [[ ! ${have[$i]:-0} =~ ^[0-9]+$ ]] || [[ ! ${want[$i]:-0} =~ ^[0-9]+$ ]]; then return 2; fi
        if [ "${have[$i]:-0}" -gt "${want[$i]:-0}" ]; then return 0; fi
        if [ "${have[$i]:-0}" -lt "${want[$i]:-0}" ]; then return 1; fi
    done
    return 0
}

# ^ invariant GITUP_ROOT is "" on a real machine; a test points GSG_GITUP_ROOT at a sandbox and every system path below moves into it
# ^ security the override only moves where files go and is announced on stderr like GSG_TOOLS_BASE_URL; it never skips a check
gitup_paths() {
    GITUP_ROOT="${GSG_GITUP_ROOT:-}"
    if [ -n "$GITUP_ROOT" ] && { [ "${GITUP_ROOT#/}" = "$GITUP_ROOT" ] || [[ $GITUP_ROOT == *[[:cntrl:]]* ]]; }; then
        printf '%s: GSG_GITUP_ROOT must be an absolute path without control characters, got [%s]\n' "$GSG_NAME" "${GITUP_ROOT//[[:cntrl:]]/?}" >&2
        return 1
    fi
    # ^ why refuse any . or .. part, not only slashes; /. and /a/.. name the filesystem root as well and the prefixes below would reach the real /usr
    if [[ $GITUP_ROOT =~ ^/+$ ]] || [[ $GITUP_ROOT =~ (^|/)\.\.?(/|$) ]]; then
        printf '%s: GSG_GITUP_ROOT must name a directory below / without . or .. parts, got [%s]\n' "$GSG_NAME" "$GSG_GITUP_ROOT" >&2
        return 1
    fi
    GITUP_ROOT="${GITUP_ROOT%/}"
    GITUP_PREFIX="$GITUP_ROOT/usr/local"
    GITUP_USRBIN="$GITUP_ROOT/usr/bin"
    GITUP_VARLIB="$GITUP_ROOT/var/lib/git-secret-guard"
    GITUP_DNFCONF="$GITUP_ROOT/etc/dnf/dnf.conf"
    GITUP_BUILD_PATH="${GSG_GITUP_BUILD_PATH:-/usr/bin:/bin}"
    # ^ invariant root-run tools (dnf, sudo, restorecon) are looked up only in this fixed list; sbin is in it, the build PATH is not
    GITUP_SYSTEM_PATH="$GITUP_BUILD_PATH"
    if [ -z "${GSG_GITUP_BUILD_PATH:-}" ]; then GITUP_SYSTEM_PATH="$GITUP_BUILD_PATH:/usr/sbin:/sbin"; fi
    GITUP_QUERY_TIMEOUT="${GSG_GITUP_QUERY_TIMEOUT:-60}"
    if [[ ! $GITUP_QUERY_TIMEOUT =~ ^[1-9][0-9]*$ ]]; then
        printf '%s: GSG_GITUP_QUERY_TIMEOUT must be a positive number of seconds, got [%s]\n' "$GSG_NAME" "${GITUP_QUERY_TIMEOUT//[[:cntrl:]]/?}" >&2
        return 1
    fi
}

# ^ security the overrides move where files go and who counts as the trusted owner; they do not skip a SHA-256 or a refusal, and they are announced
gitup_announce_overrides() {
    if [ -n "${GSG_GITUP_ROOT:-}${GSG_GITUP_BUILD_PATH:-}${GSG_GITUP_QUERY_TIMEOUT:-}${GSG_OS_RELEASE:-}" ]; then
        printf '%s: TEST OVERRIDE active (GSG_GITUP_ROOT=[%s] GSG_GITUP_BUILD_PATH=[%s] GSG_GITUP_QUERY_TIMEOUT=[%s] GSG_OS_RELEASE=[%s]); the system paths move and the current user counts as the trusted owner of the target files\n' \
            "$GSG_NAME" "${GSG_GITUP_ROOT:-}" "${GSG_GITUP_BUILD_PATH:-}" "${GSG_GITUP_QUERY_TIMEOUT:-}" "${GSG_OS_RELEASE:-}" >&2
    fi
}

# ^ invariant true when module $1 has both required functions and either all or none of the takeover capability; prints each gap
GITUP_ELEVATE_FNS=(can_elevate elevate)

# ^ invariant rc 0 when module $1 defines none or all functions of an optional group ($2 names it, the rest are suffixes); else prints each missing one
gitup_check_group() {
    local m="$1" label="$2" fn present=0 bad=0
    shift 2
    for fn in "$@"; do
        if declare -F "gitup_${m}_$fn" >/dev/null; then present=$((present + 1)); fi
    done
    if [ "$present" -eq 0 ] || [ "$present" -eq "$#" ]; then return 0; fi
    for fn in "$@"; do
        if ! declare -F "gitup_${m}_$fn" >/dev/null; then
            printf '%s: the git upgrade module %s has part of the %s capability but lacks gitup_%s_%s\n' "$GSG_NAME" "$m" "$label" "$m" "$fn" >&2
            bad=1
        fi
    done
    [ "$bad" -eq 0 ]
}

gitup_module_check() {
    local m="$1" fn bad=0
    for fn in "${GITUP_REQUIRED_FNS[@]}"; do
        if ! declare -F "gitup_${m}_$fn" >/dev/null; then
            printf '%s: the git upgrade module %s lacks the function gitup_%s_%s\n' "$GSG_NAME" "$m" "$m" "$fn" >&2
            bad=1
        fi
    done
    gitup_check_group "$m" takeover "${GITUP_TAKEOVER_FNS[@]}" || bad=1
    gitup_check_group "$m" elevation "${GITUP_ELEVATE_FNS[@]}" || bad=1
    [ "$bad" -eq 0 ]
}

# ^ security the module name comes from the registry table, never from the environment; a plain lowercase word before it names a file or a function
gitup_load_module() {
    local m="$1" file
    if [[ ! $m =~ ^[a-z][a-z0-9]*$ ]]; then
        printf '%s: the registry names the invalid git upgrade module [%s]\n' "$GSG_NAME" "${m//[[:cntrl:]]/?}" >&2
        return 1
    fi
    file="$GSG_ROOT/lib/gitup_$m.sh"
    if [ ! -f "$file" ]; then
        printf '%s: the registry names the git upgrade module %s but %s does not exist\n' "$GSG_NAME" "$m" "$file" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$file" || return 1
    gitup_module_check "$m"
}

# ^ invariant the contract test; every module the registry names loads and implements the contract, one line printed per module
gitup_check_registered_modules() {
    local class seen=" " bad=0
    for class in "${GITUP_CLASSES[@]}"; do
        gitup_registry "$class" || return 1
        if [ -z "$REPLY" ] || [[ $seen == *" $REPLY "* ]]; then continue; fi
        seen+="$REPLY "
        if gitup_load_module "$REPLY"; then printf 'checked the git upgrade module %s (class %s)\n' "$REPLY" "$class"; else bad=1; fi
    done
    [ "$bad" -eq 0 ]
}

# ^ invariant sets GITUP_CLASS, GITUP_MODULE ("" = none) and the path variables once per run; rc 1 = the module is broken or a path override is invalid
gitup_select() {
    if [ "$GITUP_SELECTED" -eq 1 ]; then return 0; fi
    gitup_paths || return 1
    gitup_os_class
    GITUP_CLASS="$REPLY"
    gitup_registry "$GITUP_CLASS" || return 1
    GITUP_MODULE="$REPLY"
    if [ -n "$GITUP_MODULE" ]; then
        gitup_announce_overrides
        gitup_load_module "$GITUP_MODULE" || return 1
    fi
    GITUP_SELECTED=1
}

# ^ invariant dispatch is the one place a function name is built from the module name; gitup_call KIND ARGS... calls gitup_<module>_<KIND>
gitup_call() {
    local kind="$1"
    shift
    "gitup_${GITUP_MODULE}_$kind" "$@"
}

gitup_has() { declare -F "gitup_${GITUP_MODULE}_$1" >/dev/null; }

# ^ invariant rc 0 = install defers the git check to the offer (git missing or old, class has a module); rc 1 = decide as before; rc 2 = module broken
gitup_defers_git() {
    gitup_select || return 2
    if [ -z "$GITUP_MODULE" ]; then return 1; fi
    install_find_git
    if [ -n "$GSG_GIT" ] && install_git_is_new_enough "$GSG_GIT"; then return 1; fi
    return 0
}

# ^ invariant adds one privileged command to the plan and prints it; the core prints the list again when nothing can elevate
# ^ invariant a bare tool name in the first word becomes the full path gitup_system_bin finds => the plan names the file gitup_elevate will run
gitup_plan_priv() {
    local text="$1" first="${1%% *}"
    if [[ $first != /* ]] && gitup_system_bin "$first"; then text="$REPLY${1#"$first"}"; fi
    GITUP_PRIV_CMDS+=("$text")
    printf '  as root: %s\n' "$text"
}

# ^ invariant a remark the plan shows beside its commands (an inner class of a WSL module, a caveat of a route); kept in GITUP_PLAN_NOTES until the next offer
GITUP_PLAN_NOTES=()
gitup_plan_note() {
    GITUP_PLAN_NOTES+=("$1")
    printf '  note: %s\n' "$1"
}

# ^ invariant gitup_delegate CLASS KIND ARGS... calls gitup_<inner>_<KIND> of the module registered for CLASS, loading it first
# ^ invariant the inner plan lines, privileged commands and notes join the same lists as the caller's
gitup_delegate() {
    local class="$1" kind="$2" inner
    shift 2
    if [[ ! $kind =~ ^[a-z_]+$ ]]; then
        printf '%s: gitup_delegate was given the invalid function kind [%s]\n' "$GSG_NAME" "${kind//[[:cntrl:]]/?}" >&2
        return 1
    fi
    gitup_registry "$class" || return 1
    inner="$REPLY"
    if [ -z "$inner" ]; then
        printf '%s: no git upgrade module is registered for the class %s\n' "$GSG_NAME" "$class" >&2
        return 1
    fi
    if ! declare -F "gitup_${inner}_$kind" >/dev/null; then gitup_load_module "$inner" || return 1; fi
    "gitup_${inner}_$kind" "$@"
}

# ^ invariant the core accumulates what changed; a module sets GITUP_CHANGED itself or appends one clause here
gitup_changed_add() {
    GITUP_CHANGED="${GITUP_CHANGED:+$GITUP_CHANGED; }$1"
}

# ^ invariant removes every clause equal to $1 as a whole from GITUP_CHANGED; each pass of the loop shortens the remainder
gitup_changed_drop() {
    local kept="" clause rest="$GITUP_CHANGED"
    if [ -z "$1" ]; then
        printf '%s: gitup_changed_drop was given an empty clause\n' "$GSG_NAME" >&2
        return 1
    fi
    while [ -n "$rest" ]; do
        clause="${rest%%; *}"
        if [ "$clause" = "$rest" ]; then rest=""; else rest="${rest#*; }"; fi
        if [ "$clause" != "$1" ]; then kept="${kept:+$kept; }$clause"; fi
    done
    GITUP_CHANGED="$kept"
}

# ^ invariant a refusal after a git upgrade of this run calls it; it names what the upgrade changed and prints nothing when nothing changed
gitup_report_changes() {
    if [ -z "$GITUP_CHANGED" ]; then return 0; fi
    printf '%s: note: %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
}

gitup_is_root() { [ "$(id -u)" -eq 0 ]; }

# ^ invariant rc 0 when the plan's privileged commands can run; a module with its own way (Windows UAC) defines gitup_<m>_can_elevate and gitup_<m>_elevate
gitup_can_elevate() {
    if gitup_has can_elevate; then
        gitup_call can_elevate
        return
    fi
    if gitup_is_root; then return 0; fi
    gitup_system_bin sudo || true
    GITUP_SUDO="$REPLY"
    [ -n "$GITUP_SUDO" ]
}

# ^ invariant runs "$@" as root through the module's elevate if it has one, directly for root, else through the system sudo; no way to elevate = rc 1
# ^ security every privileged command runs under umask 022 => a restrictive user umask cannot hide root-owned directories or change shared directory modes
# ^ security a tool given by name is looked up with gitup_system_bin, as gitup_plan_priv does; root never finds it through the caller's PATH
gitup_elevate() {
    local -a cmd=("$@")
    if gitup_has elevate; then
        (
            umask 022
            gitup_call elevate "$@"
        )
        return
    fi
    if [[ ${cmd[0]} != /* ]]; then
        if ! gitup_system_bin "${cmd[0]}"; then
            printf '%s: %s was not found in the system path (%s) or is not owned by root; nothing was run\n' "$GSG_NAME" "${cmd[0]//[[:cntrl:]]/?}" "$GITUP_SYSTEM_PATH" >&2
            return 1
        fi
        cmd[0]="$REPLY"
    fi
    if gitup_is_root; then
        (
            umask 022
            "${cmd[@]}"
        )
        return
    fi
    if [ -z "$GITUP_SUDO" ]; then gitup_can_elevate || true; fi
    if [ -z "$GITUP_SUDO" ]; then
        printf '%s: neither root nor sudo is available, cannot run: %s\n' "$GSG_NAME" "${cmd[*]}" >&2
        return 1
    fi
    (
        umask 022
        "$GITUP_SUDO" -- "${cmd[@]}"
    )
}

# ^ invariant prints the uid to own system files; root, or the current user when a test moved the system paths with GSG_GITUP_ROOT
gitup_trusted_uid() {
    if [ -n "${GITUP_ROOT:-}" ]; then id -u; else printf '0\n'; fi
}

# ^ security NAME is looked up only in the fixed system path, never in the caller's PATH
# ^ invariant it must be a regular executable owned by the trusted user, not writable by group or others
# ^ invariant sets REPLY = the full path of NAME; rc 1 leaves REPLY empty
gitup_system_bin() {
    local d p stat_out uid mode
    local -a dirs=()
    REPLY=""
    if [ -z "${GITUP_SYSTEM_PATH:-}" ]; then gitup_paths || return 1; fi
    IFS=: read -r -a dirs <<<"$GITUP_SYSTEM_PATH"
    for d in "${dirs[@]}"; do
        p="$d/$1"
        if [ ! -f "$p" ] || [ ! -x "$p" ]; then continue; fi
        stat_out="$(stat -L -c '%u %a' -- "$p")" || continue
        read -r uid mode <<<"$stat_out"
        if [ "$uid" != "$(gitup_trusted_uid)" ] || [ $((8#$mode & 8#022)) -ne 0 ]; then continue; fi
        REPLY="$p"
        return 0
    done
    return 1
}

# ^ invariant rc 0 when the plan's privileged commands can run; otherwise prints them for the user to run as root, changes nothing and returns 1
gitup_need_elevation() {
    local cmd skipped=0
    if [ "${#GITUP_PRIV_CMDS[@]}" -eq 0 ] || gitup_can_elevate; then return 0; fi
    printf '%s: neither root nor sudo is available, so nothing was run; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
    if [ "${GITUP_PRIV_BYHAND:-1}" -eq 0 ]; then
        printf '%s: run %s install --upgrade-git as root, or install sudo; its commands depend on checks that only install makes between them (a signing key, a version floor), so they are not listed to be typed by hand\n' \
            "$GSG_NAME" "$GSG_NAME" >&2
        return 1
    fi
    printf '%s: run these commands as root, then run install again:\n' "$GSG_NAME" >&2
    for cmd in "${GITUP_PRIV_CMDS[@]}"; do
        # ^ why a skip, not a rewrite; a <placeholder> names a file or directory only the run knows, an [only when ...] line is no command of its own
        if [[ $cmd == *"<"*">"* || $cmd == *"[only when"* ]]; then
            skipped=1
            continue
        fi
        printf '  %s\n' "$cmd" >&2
    done
    if [ "$skipped" -eq 1 ]; then
        printf '%s: other commands of the plan (the ones with a <placeholder>, such as the copy from <build dir>, or a condition on the machine) use what this tool builds as your user or depend on the machine and cannot be typed by hand; run the whole install as root, or install sudo\n' "$GSG_NAME" >&2
    fi
    return 1
}

# ^ invariant rc 0 = yes (the flag, or y or yes at the prompt), 1 = no (anything else, the default), 2 = no flag and no terminal
# ^ invariant it prompts only when stdin and stderr are both terminals
gitup_consent() {
    local flag="$1" question="$2" answer=""
    if [ "$flag" -eq 1 ]; then return 0; fi
    if [ ! -t 0 ] || [ ! -t 2 ]; then return 2; fi
    printf '%s: %s [y/N] ' "$GSG_NAME" "$question" >&2
    read -r answer || answer=""
    case "$answer" in
        y | Y | yes | YES | Yes) return 0 ;;
    esac
    return 1
}

gitup_describe_git() {
    local ver
    if [ -z "$GSG_GIT" ]; then
        printf 'no git was found on PATH'
        return 0
    fi
    ver="$(install_git_version "$GSG_GIT")" || ver="of unknown version"
    printf 'the git on PATH (%s) is git %s' "$GSG_GIT" "$ver"
}

gitup_refuse_path_fix() {
    local dir="${GITUP_FOUND_GIT%/*}"
    # shellcheck disable=SC2016
    printf '%s: a git >= 2.54 is installed at %s but is not the first git on PATH; put %s first on PATH, for example: export PATH="%s:$PATH"; no shell profile was edited, %s\n' \
        "$GSG_NAME" "$GITUP_FOUND_GIT" "$dir" "$dir" "$(brew_unchanged_text)" >&2
}

# ^ invariant after a good apply PATH is read again (hash -r); the git found must be >= 2.54 or install refuses and says what the upgrade changed
GITUP_NEW_GIT=""
gitup_reverify() {
    local hint="put the directory of the new git first on PATH"
    hash -r
    install_find_git
    if [ -z "$GITUP_CHANGED" ]; then GITUP_CHANGED="the $GITUP_MODULE module upgraded git"; fi
    if [ -n "$GSG_GIT" ] && install_git_is_new_enough "$GSG_GIT"; then
        GITUP_PENDING=0
        printf '%s: %s now; continuing\n' "$GSG_NAME" "$(gitup_describe_git)"
        return 0
    fi
    # shellcheck disable=SC2016
    if [ -n "$GITUP_NEW_GIT" ]; then hint="put ${GITUP_NEW_GIT%/*} first on PATH, for example: export PATH=\"${GITUP_NEW_GIT%/*}:\$PATH\"; no shell profile was edited"; fi
    printf '%s: the git upgrade finished but %s, and config-based hooks need git >= 2.54; %s; install refused, %s\n' \
        "$GSG_NAME" "$(gitup_describe_git)" "$hint" "$(brew_unchanged_text)" >&2
    return 1
}

# ^ invariant rc 0 = apply finished; rc 1 = failed (a refusal naming what changed); rc 3 = the module hands off and install stops with the next step printed
GITUP_IN_APPLY=0
# ^ hazard a wrapper module without abort => the half-made change of the inner module stays after an interrupt; doc:CONTRIBUTING.md
# ^ invariant install_cleanup calls it with the exit status on every exit
# ^ invariant a module's optional gitup_<m>_abort gets one call when the process ends inside an apply or takeover_apply
gitup_abort_cleanup() {
    local rc="$1"
    if [ "$GITUP_IN_APPLY" -ne 1 ]; then return 0; fi
    GITUP_IN_APPLY=0
    if gitup_has abort; then gitup_call abort || printf '%s: the %s module could not undo its unfinished step\n' "$GSG_NAME" "$GITUP_MODULE" >&2; fi
    GITUP_APPLY_FAILED=1
    if [ "$rc" -ge 129 ] && [ -n "$GITUP_CHANGED" ]; then printf '%s: interrupted; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2; fi
}

gitup_run_apply() {
    local rc
    GITUP_NEXT="" GITUP_NEW_GIT=""
    GITUP_IN_APPLY=1
    gitup_call apply
    rc=$?
    GITUP_IN_APPLY=0
    case "$rc" in
        0) return 0 ;;
        2)
            printf '%s: the git upgrade must be finished outside this process; install stopped and the git on this machine stays as it was until that step is done; next: %s\n' \
                "$GSG_NAME" "${GITUP_NEXT:-see the output above}"
            return 3
            ;;
        *)
            GITUP_APPLY_FAILED=1
            printf '%s: the git upgrade failed (the %s module returned %s); install refused, %s\n' "$GSG_NAME" "$GITUP_MODULE" "$rc" "$(brew_unchanged_text)" >&2
            return 1
            ;;
    esac
}

gitup_offer_upgrade() {
    local rc crc extra=""
    GITUP_PRIV_CMDS=() GITUP_PRIV_BYHAND=1 GITUP_ROUTE="" GITUP_FOUND_GIT="" GITUP_NEXT=""
    printf '%s: %s; config-based hooks need git >= 2.54\n' "$GSG_NAME" "$(gitup_describe_git)"
    printf '%s: git upgrade plan for this %s system (module %s):\n' "$GSG_NAME" "$GITUP_CLASS" "$GITUP_MODULE"
    gitup_call plan upgrade
    rc=$?
    if [ "$rc" -ne 0 ]; then
        # ^ invariant a refused plan means --upgrade-git would refuse too => the hint after it must not recommend the flag
        GITUP_PLAN_REFUSED=1
        install_require_git
        return 1
    fi
    case "$GITUP_ROUTE" in
        "")
            printf '%s: the %s module planned an upgrade without setting GITUP_ROUTE; install refused, %s\n' "$GSG_NAME" "$GITUP_MODULE" "$(brew_unchanged_text)" >&2
            return 1
            ;;
        path-fix)
            gitup_refuse_path_fix
            return 1
            ;;
    esac
    gitup_consent "$GITUP_UPGRADE_FLAG" "Upgrade git now with the plan above?"
    crc=$?
    if [ "$crc" -ne 0 ]; then
        if [ "$crc" -eq 2 ]; then extra=" (there is no terminal to ask on, so the flag is the only way to say yes)"; fi
        install_require_git
        printf '%s: %s; to let install upgrade git run: %s install --upgrade-git%s\n' "$GSG_NAME" "$(brew_unchanged_text)" "$GSG_NAME" "$extra" >&2
        return 1
    fi
    gitup_need_elevation || return 1
    gitup_run_apply || return $?
    gitup_reverify
}

# ^ invariant the pin-bump offer; git is fine and the module's refresh plan says whether a build of ours is older than the pin
# ^ invariant a refresh plan prints nothing and returns 1 when nothing is stale; declining or having no terminal continues the install
gitup_offer_refresh() {
    local crc rc
    GITUP_PRIV_CMDS=() GITUP_PRIV_BYHAND=1 GITUP_PLAN_NOTES=() GITUP_ROUTE="" GITUP_FOUND_GIT="" GITUP_NEXT=""
    gitup_call plan refresh
    rc=$?
    if [ "$rc" -eq 2 ]; then
        if [ "$GITUP_UPGRADE_FLAG" -eq 1 ]; then
            printf '%s: the git rebuild asked for with --upgrade-git cannot be done now; install refused, %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
            return 1
        fi
        return 0
    fi
    if [ "$rc" -ne 0 ]; then return 0; fi
    gitup_consent "$GITUP_UPGRADE_FLAG" "Rebuild git now with the plan above?"
    crc=$?
    if [ "$crc" -ne 0 ]; then
        printf '%s: git was left as it is; to rebuild it run: %s install --upgrade-git\n' "$GSG_NAME" "$GSG_NAME"
        return 0
    fi
    gitup_need_elevation || return 1
    gitup_run_apply || return $?
    gitup_reverify
}

# ^ invariant the takeover is offered only for a git older than 2.54 the module can take over, and only when its plan finds the target safe
# ^ invariant a takeover plan prints only when it returns 0; on 1 (refused) and 2 (nothing to do) it sets GITUP_REASON, and without the flag a refusal is silent
gitup_offer_takeover() {
    local i cand found="" rc crc
    if ! gitup_has takeover_supported; then return 0; fi
    install_collect_gits
    for i in "${!GSG_GIT_CANDIDATES[@]}"; do
        cand="${GSG_GIT_CANDIDATES[$i]}"
        if install_git_is_new_enough "$cand"; then continue; fi
        if gitup_call takeover_supported "${GSG_GIT_REAL[$i]}"; then
            found="$cand"
            break
        fi
    done
    if [ -z "$found" ] && gitup_system_git_state && { [ "$GITUP_TK_STATE" = undone ] || [ "$GITUP_TK_STATE" = broken ]; } && [ -n "$GITUP_TK_TARGET" ]; then found="$GITUP_TK_TARGET"; fi
    if [ -z "$found" ]; then
        if [ "$GITUP_TAKEOVER_FLAG" -eq 1 ]; then
            if gitup_system_git_state && [ "$GITUP_TK_STATE" = active ]; then
                printf '%s: nothing to take over: the system git takeover is already active (%s)\n' "$GSG_NAME" "$GITUP_TK_TEXT"
            else
                printf '%s: nothing to take over: no git older than 2.54 that install can take over on a system of class %s is reachable\n' "$GSG_NAME" "$GITUP_CLASS"
            fi
        fi
        return 0
    fi
    GITUP_PRIV_CMDS=() GITUP_PLAN_NOTES=() GITUP_REASON=""
    gitup_call takeover_plan "$found"
    rc=$?
    if [ "$rc" -eq 2 ]; then
        if [ "$GITUP_TAKEOVER_FLAG" -eq 1 ]; then printf '%s: nothing to take over: %s\n' "$GSG_NAME" "$GITUP_REASON"; fi
        return 0
    fi
    if [ "$rc" -ne 0 ]; then
        if [ "$GITUP_TAKEOVER_FLAG" -eq 1 ]; then
            printf '%s: the system git takeover was refused: %s; install refused, %s\n' "$GSG_NAME" "$GITUP_REASON" "$(brew_unchanged_text)" >&2
            return 1
        fi
        return 0
    fi
    gitup_consent "$GITUP_TAKEOVER_FLAG" "Take over $found with the plan above?"
    crc=$?
    if [ "$crc" -ne 0 ]; then
        printf '%s: %s was left as it is; to take it over run: %s install --take-over-system-git\n' "$GSG_NAME" "$found" "$GSG_NAME"
        return 0
    fi
    gitup_need_elevation || return 1
    GITUP_REASON=""
    GITUP_IN_APPLY=1
    gitup_call takeover_apply "$found" || {
        GITUP_IN_APPLY=0
        printf '%s: the system git takeover failed: %s; install refused, %s\n' "$GSG_NAME" "${GITUP_REASON:-see the output above}" "$(brew_unchanged_text)" >&2
        return 1
    }
    GITUP_IN_APPLY=0
}

# ^ invariant the one entry the installer calls after its other refusable checks; rc 0 = go on, 1 = refused, 3 = a module handed off and install stops
# ^ order the upgrade or the rebuild runs before the takeover offer, since a takeover needs the build the upgrade just made
gitup_offers() {
    local rc
    GITUP_UPGRADE_FLAG="$1" GITUP_TAKEOVER_FLAG="$2"
    gitup_select || return 1
    if [ "$GITUP_TAKEOVER_FLAG" -eq 1 ] && { [ -z "$GITUP_MODULE" ] || ! gitup_has takeover_supported; }; then
        if [ -n "$GITUP_MODULE" ] && gitup_has takeover_unavailable; then
            printf '%s: --take-over-system-git cannot be done here: %s\n' "$GSG_NAME" "$(gitup_call takeover_unavailable)"
        else
            printf '%s: --take-over-system-git is not available on a system of class %s; install refused, %s\n' "$GSG_NAME" "$GITUP_CLASS" "$(brew_unchanged_text)" >&2
            return 1
        fi
    fi
    if [ -z "$GITUP_MODULE" ]; then return 0; fi
    if [ "$GITUP_PENDING" -eq 1 ]; then gitup_offer_upgrade; else gitup_offer_refresh; fi
    rc=$?
    if [ "$rc" -ne 0 ]; then return "$rc"; fi
    gitup_offer_takeover
}

# ^ invariant prints the sentence the other-git warning adds for a git the module could take over; nothing for any other git
gitup_takeover_note() {
    if [ -z "$GITUP_MODULE" ] || ! gitup_has takeover_supported || ! gitup_call takeover_supported "$1"; then return 0; fi
    printf '; cron jobs and scripts that call %s by its full path are not scanned either, and %s install --take-over-system-git can point it at the new git' "$1" "$GSG_NAME"
}

# ^ invariant a module's takeover_status sets GITUP_TK_STATE (none, active, undone or broken), GITUP_TK_TEXT (one line) and GITUP_TK_HOWTO (the undo by hand)
# ^ invariant GITUP_TK_TARGET = the path takeover_plan is given when the state is undone (an unfinished takeover is offered again)
GITUP_TK_STATE=none GITUP_TK_TEXT="" GITUP_TK_HOWTO="" GITUP_TK_TARGET=""

# ^ invariant rc 0 = the class has a takeover capability and the GITUP_TK variables describe the machine now; rc 1 = nothing to report
gitup_system_git_state() {
    gitup_select || return 1
    if [ -z "$GITUP_MODULE" ] || ! gitup_has takeover_status; then return 1; fi
    gitup_call takeover_status
}

# ^ invariant the restore-system-git command; rc 0 = restored or nothing to restore, and the module restores from its own record with no network
gitup_restore_run() {
    gitup_select || return 1
    if ! gitup_system_git_state; then
        printf '%s: nothing to restore: a system of class %s has no system git takeover\n' "$GSG_NAME" "$GITUP_CLASS"
        return 0
    fi
    if [ "$GITUP_TK_STATE" != none ]; then
        GITUP_PRIV_CMDS=("$GSG_NAME restore-system-git")
        gitup_need_elevation || return 1
    fi
    gitup_call takeover_restore
}

# ^ invariant uninstall stops in every takeover state except none (active, partial, undone, broken); --keep-system-git prints the undo by hand and goes on
# ^ why stop for a half done takeover, not a note; uninstall removes restore-system-git, and links or the dnf entry would stay with no command to undo them
gitup_takeover_guard() {
    if ! gitup_system_git_state; then return 0; fi
    if [ "$GITUP_TK_STATE" = none ]; then return 0; fi
    if [ "${1:-0}" -ne 1 ]; then
        printf '%s: a system git takeover is in place or half done (%s); uninstall changed nothing. Run %s restore-system-git first, or %s uninstall --keep-system-git to uninstall, leave it as it is and print the commands to undo it by hand\n' \
            "$GSG_NAME" "$GITUP_TK_TEXT" "$GSG_NAME" "$GSG_NAME" >&2
        return 1
    fi
    printf '%s: keeping the system git takeover. Once uninstall has removed %s restore-system-git, undo it by hand:\n%s\n' "$GSG_NAME" "$GSG_NAME" "$GITUP_TK_HOWTO"
}
