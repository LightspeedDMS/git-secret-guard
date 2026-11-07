# shellcheck shell=bash disable=SC2153,SC2034

GSG_HP_MAX_INCLUDES=64

# ^ invariant runs git once; fills GSG_HP_OUT with its NUL separated records and GSG_HP_ERR with the first line of its stderr; returns git's own exit status
hp_records() {
    local errf rc keep="${REPLY-}"
    GSG_HP_OUT=() GSG_HP_ERR=""
    errf="$(mktemp)" || return 125
    mapfile -d '' -t GSG_HP_OUT < <("$GSG_GIT" "$@" 2>"$errf")
    wait "$!"
    rc=$?
    GSG_HP_ERR="$(head -n 1 -- "$errf" | head -c 2000)"
    GSG_HP_ERR="${GSG_HP_ERR//[^[:print:]]/?}"
    trunc_text "$GSG_HP_ERR" 200
    GSG_HP_ERR="$REPLY"
    REPLY="$keep"
    rm -f -- "$errf"
    return "$rc"
}

# ^ invariant git config --global exits 129 with "only one config file at a time" when GIT_CONFIG is set => the message names it
hp_report_failure() {
    printf '%s: cannot read the global git config (%s exit %s)%s\n' "$GSG_NAME" "$1" "$2" "${GSG_HP_ERR:+: $GSG_HP_ERR}" >&2
    if [ -n "${GIT_CONFIG:-}" ]; then
        printf '%s: GIT_CONFIG is set in the environment [%s]; git config --global refuses it, unset it and run again\n' "$GSG_NAME" "$GIT_CONFIG" >&2
    fi
}

lifecycle_note_global_config() {
    if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
        printf '%s: note: GIT_CONFIG_GLOBAL is set; the global git config used is %s\n' "$GSG_NAME" "$GIT_CONFIG_GLOBAL" >&2
    fi
}

# ^ external BSD realpath (macOS) has no -m and this read runs before brew installs the GNU one; a probe on / names the realpath in use
# ^ invariant a realpath with -m is called exactly as before; without it the fallback refuses a relative path and returns 1 for an unresolvable ancestor
lifecycle_realpath_m() {
    local p="$1" head tail="" comp out
    local -a comps
    if realpath -m -- / >/dev/null 2>&1; then
        realpath -m -- "$p"
        return
    fi
    case "$p" in
        /*) ;;
        *) return 1 ;;
    esac
    head="$p"
    while [ "$head" != / ] && [ ! -e "$head" ] && [ ! -L "$head" ]; do
        tail="/${head##*/}$tail"
        head="${head%/*}"
        if [ -z "$head" ]; then head=/; fi
    done
    out="$(realpath -- "$head")" || return 1
    IFS=/ read -r -a comps <<<"$tail"
    for comp in "${comps[@]}"; do
        case "$comp" in
            "" | .) ;;
            ..)
                out="${out%/*}"
                if [ -z "$out" ]; then out=/; fi
                ;;
            *)
                if [ "$out" = / ]; then out="/$comp"; else out="$out/$comp"; fi
                ;;
        esac
    done
    printf '%s\n' "$out"
}

# ^ invariant always returns 1; the refusal for a global config file whose real path cannot be resolved, claim included
hp_report_unresolved() {
    printf '%s: cannot resolve the include path %s of the global git config; %s\n' "$GSG_NAME" "$1" "$(brew_unchanged_text)" >&2
    return 1
}

# ^ external an include.path is resolved against the including file's directory, "~/" against HOME; a missing target is ignored by git
hp_include_target() {
    local base="$1" p="$2" out
    # shellcheck disable=SC2088
    case "$p" in
        '~/'*) p="$HOME/${p#'~/'}" ;;
        /*) ;;
        *) p="${base%/*}/$p" ;;
    esac
    if out="$(lifecycle_realpath_m "$p" 2>/dev/null)"; then
        printf '%s\n' "$out"
        return 0
    fi
    # ^ invariant a missing target (dangling symlink, loop) prints nothing and succeeds => git ignores it and the walk skips an empty path
    if [ ! -e "$p" ]; then return 0; fi
    hp_report_unresolved "$p"
}

# ^ why a static walk, not only git's answer; includeIf gitdir and onbranch need a repository, git shows their values only inside one
# ^ invariant every include target is read as if its condition held; over GSG_HP_MAX_INCLUDES files => refuse, never stop quietly
# ^ external probed git 2.56 -z layouts, --get-all = "value NUL", --get-regexp = "key NL value NUL"
hp_walk_includes() {
    local q cand v rec reads=0 rc
    for ((q = 0; q < ${#GSG_HP_Q_BASE[@]}; q++)); do
        cand="$(hp_include_target "${GSG_HP_Q_BASE[q]}" "${GSG_HP_Q_PATH[q]}")" || return 1
        if [ ! -f "$cand" ] || [ ! -r "$cand" ] || [[ -n ${GSG_HP_SEEN[$cand]:-} ]]; then continue; fi
        GSG_HP_SEEN[$cand]=1
        reads=$((reads + 1))
        if [ "$reads" -gt "$GSG_HP_MAX_INCLUDES" ]; then
            printf '%s: more than %s included git config files; cannot tell whether one sets core.hooksPath, install refused\n' "$GSG_NAME" "$GSG_HP_MAX_INCLUDES" >&2
            return 1
        fi
        hp_records config --file "$cand" -z --get-all core.hooksPath
        rc=$?
        if [ "$rc" -gt 1 ]; then
            printf '%s: cannot read the included git config %s (git config exit %s)%s\n' "$GSG_NAME" "$cand" "$rc" "${GSG_HP_ERR:+: $GSG_HP_ERR}" >&2
            return 1
        fi
        for v in "${GSG_HP_OUT[@]}"; do
            GSG_HP_FOREIGN_FILE+=("$cand")
            GSG_HP_FOREIGN_VALUE+=("$v")
        done
        hp_records config --file "$cand" -z --get-regexp '^include(if\..*)?\.path$'
        rc=$?
        if [ "$rc" -gt 1 ]; then
            printf '%s: cannot read the included git config %s (git config exit %s)%s\n' "$GSG_NAME" "$cand" "$rc" "${GSG_HP_ERR:+: $GSG_HP_ERR}" >&2
            return 1
        fi
        for rec in "${GSG_HP_OUT[@]}"; do
            if [[ $rec != *$'\n'* ]]; then continue; fi
            GSG_HP_Q_BASE+=("$cand")
            GSG_HP_Q_PATH+=("${rec#*$'\n'}")
        done
    done
}

# ^ external git config --global reads only the one file it edits and follows no include, yet XDG and included files apply with global scope (git 2.56)
# ^ invariant sets GSG_HP_OWN and GSG_HP_FILE ("file:<path>") for the file git config --global edits; GSG_HP_FILE = "" when it holds no value
# ^ invariant sets GSG_HP_FOREIGN_FILE and GSG_HP_FOREIGN_VALUE = parallel arrays for global-scope values in any other file; valueless counts as ""
lifecycle_read_hooks_path() {
    local -r not_found=1 own_fields=2 list_fields=3
    local rc i scope origin kv key value path real
    local -A seen_origin=()
    GSG_HP_OWN=() GSG_HP_FILE="" GSG_HP_FOREIGN_FILE=() GSG_HP_FOREIGN_VALUE=()
    GSG_HP_Q_BASE=() GSG_HP_Q_PATH=()
    declare -gA GSG_HP_SEEN=()
    # ^ external probed git 2.56 -z layouts, --show-origin --get-all = "origin NUL value NUL", --list = "scope NUL origin NUL key NL value NUL"
    hp_records config --global --show-origin -z --get-all core.hooksPath
    rc=$?
    if [ "$rc" -gt "$not_found" ]; then
        hp_report_failure "git config" "$rc"
        return 1
    fi
    for ((i = 0; i + 1 < ${#GSG_HP_OUT[@]}; i += own_fields)); do
        GSG_HP_FILE="${GSG_HP_OUT[i]}"
        GSG_HP_OWN+=("${GSG_HP_OUT[i + 1]}")
    done
    # ^ why -C /, not the current directory; a repository there adds its own local config and conditional includes
    hp_records -C / config --show-scope --show-origin -z --list
    rc=$?
    if [ "$rc" -ne 0 ]; then
        hp_report_failure "git config --list" "$rc"
        return 1
    fi
    for ((i = 0; i + 2 < ${#GSG_HP_OUT[@]}; i += list_fields)); do
        scope="${GSG_HP_OUT[i]}"
        origin="${GSG_HP_OUT[i + 1]}"
        kv="${GSG_HP_OUT[i + 2]}"
        if [ "$scope" != global ] || [[ $origin != file:* ]]; then continue; fi
        path="${origin#file:}"
        if [[ -z ${seen_origin[$origin]:-} ]]; then
            seen_origin[$origin]=1
            real="$(lifecycle_realpath_m "$path" 2>/dev/null)" || hp_report_unresolved "$path" || return 1
            GSG_HP_SEEN[$real]=1
        fi
        key="${kv%%$'\n'*}"
        value=""
        if [[ $kv == *$'\n'* ]]; then value="${kv#*$'\n'}"; fi
        case "$key" in
            core.hookspath)
                if [ "$origin" != "$GSG_HP_FILE" ]; then
                    GSG_HP_FOREIGN_FILE+=("$path")
                    GSG_HP_FOREIGN_VALUE+=("$value")
                fi
                ;;
            include.path | includeif.*.path)
                if [[ $kv == *$'\n'* ]]; then
                    GSG_HP_Q_BASE+=("$path")
                    GSG_HP_Q_PATH+=("$value")
                fi
                ;;
        esac
    done
    hp_walk_includes
}

# ^ invariant prints the files git --global may create, GIT_CONFIG_GLOBAL alone when set, else ~/.gitconfig and the XDG git/config
install_global_config_files() {
    if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then
        printf '%s\n' "$GIT_CONFIG_GLOBAL"
        return 0
    fi
    printf '%s\n' "${HOME:-/nonexistent}/.gitconfig" "${XDG_CONFIG_HOME:-${HOME:-/nonexistent}/.config}/git/config"
}

# ^ invariant prints PATH when missing, or the missing target of a dangling symlink at PATH; the probe may create exactly what this prints
install_config_probe_site() {
    local f="$1" t
    if [ ! -e "$f" ] && [ ! -L "$f" ]; then
        printf '%s\n' "$f"
        return 0
    fi
    if [ -L "$f" ] && [ ! -e "$f" ]; then
        t="$(readlink -- "$f")" || return 0
        if [[ $t != /* ]]; then t="${f%/*}/$t"; fi
        if [ ! -e "$t" ] && [ ! -L "$t" ]; then printf '%s\n' "$t"; fi
    fi
    return 0
}

# ^ why a write probe, not git config --list; --list exits 128 for a missing file too = a normal fresh machine
# ^ order before the first download or copy => an unwritable global config leaves nothing half installed
# ^ invariant a config file the probe created is removed again when it is empty => a refusal after the probe still leaves the machine as it was
install_check_config_writable() {
    local f t ok=1
    local -a absent=()
    while IFS= read -r f; do
        t="$(install_config_probe_site "$f")"
        if [ -n "$t" ]; then absent+=("$t"); fi
    done < <(install_global_config_files)
    if "$GSG_GIT" config --global gsg-install-probe.ok 1 2>/dev/null; then
        if "$GSG_GIT" config --global --remove-section gsg-install-probe 2>/dev/null; then ok=0; fi
    fi
    for f in "${absent[@]}"; do
        if [ -f "$f" ] && [ ! -L "$f" ] && [ ! -s "$f" ]; then rm -f -- "$f" || printf '%s: could not remove the empty %s the probe created\n' "$GSG_NAME" "$f" >&2; fi
    done
    if [ "$ok" -eq 0 ]; then return 0; fi
    printf '%s: cannot write the global git config; %s\n' "$GSG_NAME" "$(brew_unchanged_text)" >&2
    return 1
}

# ^ external hook list line = name, "disabled<TAB>name" (enabled=false) or "event-disabled<TAB>name" (hook.pre-commit.enabled=false); git 2.56
# ^ invariant hooklist_read ERRFILE [GIT_ARGS...] sets HL_STATUS = effective, disabled, event-disabled or absent; HL_RC = git's exit status; REPLY = its message
# ^ invariant HL_BOUND = the timeout command prefix for the git call (empty = unbounded); status sets it from the settings, doctor's git is its own bounded shim
HL_BOUND=()

# ^ invariant the bound is 30 seconds under the settings' timeout binary; without usable settings the call is unbounded, and it runs no user hook
hooklist_bind_timeout() {
    HL_BOUND=()
    if load_settings "$GSG_SHARE/settings" 2>/dev/null && ! tool_unusable timeout "${TIMEOUT_BIN:-}" >/dev/null; then HL_BOUND=("$TIMEOUT_BIN" -k 5 30); fi
}
# ^ invariant returns 0 = listed (an empty list too, also a command without its event), 2 = an event without its command (git exits 128), 1 = git failed
hooklist_read() {
    local errfile="$1" line
    local -a listed=()
    shift
    HL_STATUS=absent
    mapfile -t listed < <("${HL_BOUND[@]}" "$GSG_GIT" "$@" hook list pre-commit 2>"$errfile")
    wait "$!"
    HL_RC=$?
    first_message "$errfile"
    # ^ external hook list exit 1 + "no hooks found" on stderr = an empty list, not a failure
    # ^ external git 2.56 exits 128 with "'hook.git-secret-guard.command' must be configured or ... must be removed" when only the command key is gone
    if [ "$HL_RC" -ne 0 ] && [[ $REPLY == *"must be configured or"* ]]; then return 2; fi
    if [ "$HL_RC" -ne 0 ] && { [ "$HL_RC" -ne 1 ] || [[ $REPLY != *"no hooks found"* ]]; }; then return 1; fi
    for line in "${listed[@]}"; do
        case "$line" in
            git-secret-guard) HL_STATUS=effective ;;
            $'disabled\tgit-secret-guard') HL_STATUS=disabled ;;
            $'event-disabled\tgit-secret-guard') HL_STATUS=event-disabled ;;
        esac
    done
    return 0
}

# ^ security every local variable git names is unset (GIT_DIR and the like); GIT_CONFIG_PARAMETERS and GIT_CONFIG_COUNT stay, a commit sees them too
# ^ security no git init => it writes HEAD and fires reference-transaction hooks (core.hooksPath and config); the bare repository is built by hand
# ^ invariant hooklist_probe WORK = git hook list on HEAD, objects/ and refs/ written below WORK; rc 0 sets HL_STATUS, rc 1 HL_STEP HL_RC REPLY (subshell only)
hooklist_probe() {
    local work="$1" vars v rc repo="$1/repo"
    if tools_is_windows; then repo="$(cygpath -m "$work")/repo" || repo="$work/repo"; fi
    HL_STEP="rev-parse --local-env-vars"
    vars="$("$GSG_GIT" rev-parse --local-env-vars 2>"$work/err.txt")"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        first_message "$work/err.txt"
        HL_RC="$rc"
        return 1
    fi
    while IFS= read -r v; do
        case "$v" in
            "" | GIT_CONFIG_PARAMETERS | GIT_CONFIG_COUNT) continue ;;
        esac
        unset "$v"
    done <<<"$vars"
    unset GIT_DEFAULT_HASH GIT_DEFAULT_REF_FORMAT
    HL_STEP="build the probe repository"
    if ! mkdir -p -- "$work/repo/objects" "$work/repo/refs" || ! printf 'ref: refs/heads/main\n' >"$work/repo/HEAD"; then
        HL_RC=1
        REPLY="cannot write below the temp directory"
        return 1
    fi
    HL_STEP="hook list pre-commit"
    hooklist_read "$work/err.txt" --git-dir="$repo"
}

# ^ invariant prints "ok<TAB>STATUS" or "fail<TAB>STEP<TAB>EXIT<TAB>MESSAGE" for the caller to parse; the probe unsets stay in its subshell
hooklist_probe_line() {
    (
        if hooklist_probe "$1"; then
            printf 'ok\t%s\n' "$HL_STATUS"
        else
            printf 'fail\t%s\t%s\t%s\n' "$HL_STEP" "$HL_RC" "$REPLY"
        fi
    )
}

# ^ external hook.c parses EACH enabled value with git_parse_maybe_bool and skips unparseable ones => the last valid value decides (v2.54.0, v2.55.0)
# ^ external a valueless hook.<name>.enabled makes git add, commit, init and clone exit 128 in whichever scope it sits, even when a later scope sets true
# ^ invariant location only, git hook list decides => names the setting git blamed (off, unjudged, valueless) with key, scope, file, value; rc 1 = unreadable
hp_hook_enabled_scan() {
    local rc i j key scope origin rec dec decval bad
    # ^ why no git version gate, not the 2.55 rule; git reports event-disabled only where it reads hook.<event>.enabled
    local -a r_key=() r_scope=() r_origin=() r_value=()
    HP_EN_KIND=() HP_EN_KEY=() HP_EN_SCOPE=() HP_EN_ORIGIN=() HP_EN_VALUE=()
    hp_records -C / config --show-scope --show-origin -z --get-regexp '^hook\.(git-secret-guard|pre-commit)\.enabled$'
    rc=$?
    if [ "$rc" -gt 1 ]; then return 1; fi
    for ((i = 0; i + 2 < ${#GSG_HP_OUT[@]}; i += 3)); do
        scope="${GSG_HP_OUT[i]}" origin="${GSG_HP_OUT[i + 1]}" rec="${GSG_HP_OUT[i + 2]}"
        key="${rec%%$'\n'*}"
        if [[ $rec != *$'\n'* ]]; then
            HP_EN_KIND+=(valueless) HP_EN_KEY+=("$key") HP_EN_SCOPE+=("$scope") HP_EN_ORIGIN+=("$origin") HP_EN_VALUE+=("")
            continue
        fi
        r_key+=("$key") r_scope+=("$scope") r_origin+=("$origin") r_value+=("${rec#*$'\n'}")
    done
    for key in hook.git-secret-guard.enabled hook.pre-commit.enabled; do
        dec=-1 decval="" bad=-1
        for j in "${!r_key[@]}"; do
            if [ "${r_key[$j]}" != "$key" ]; then continue; fi
            hp_bool_value "${r_value[$j]}"
            rc=$?
            if [ "$rc" -eq 0 ]; then
                dec="$j" decval="$REPLY"
            elif [ "$rc" -eq 2 ]; then
                bad="$j"
                r_value[bad]="$REPLY"
                break
            fi
        done
        if [ "$bad" -ge 0 ]; then
            HP_EN_KIND+=(unjudged) HP_EN_KEY+=("$key") HP_EN_SCOPE+=("${r_scope[$bad]}") HP_EN_ORIGIN+=("${r_origin[$bad]}") HP_EN_VALUE+=("${r_value[$bad]}")
        elif [ "$dec" -ge 0 ] && [ "$decval" = false ]; then
            HP_EN_KIND+=(off) HP_EN_KEY+=("$key") HP_EN_SCOPE+=("${r_scope[$dec]}") HP_EN_ORIGIN+=("${r_origin[$dec]}") HP_EN_VALUE+=("${r_value[$dec]}")
        fi
    done
}

# ^ external one value through git's own boolean parser (00, 0k, 0x0, -0 and empty are false); no config file is read, LC_ALL=C pins the text
# ^ external git 2.56 rejects a value with exit 128 and the text bad boolean config value X for gsg.probe; only this text means not-a-boolean
# ^ invariant sets REPLY = true | false (rc 0), "" (rc 1, git cannot parse it), or git's first output line (rc 2, the probe failed for another reason)
hp_bool_value() {
    local out rc=0
    out="$(GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1 LC_ALL=C "$GSG_GIT" -C / -c "gsg.probe=$1" config --type=bool --get gsg.probe 2>&1)" || rc=$?
    REPLY="$out"
    if [ "$rc" -eq 0 ] && { [ "$out" = true ] || [ "$out" = false ]; }; then return 0; fi
    if [[ $out == "fatal: bad boolean config value "*" for 'gsg.probe'" ]]; then
        REPLY=""
        return 1
    fi
    REPLY="${out%%$'\n'*}"
    return 2
}

# ^ invariant sets REPLY = how to remove entry I; the git config form only for the global file git writes, else the named file to edit
# ^ why the named file, not a system unset; an unset needs root, fails for an included file or a command-line setting
hp_hook_enabled_advice() {
    local i="$1" file="${HP_EN_ORIGIN[$1]#file:}" scope="${HP_EN_SCOPE[$1]}" main=""
    file="${file//[^[:print:]]/?}"
    case "$scope" in
        global)
            if [ -n "${GIT_CONFIG_GLOBAL:-}" ]; then main="$GIT_CONFIG_GLOBAL"; else main="${HOME:-}/.gitconfig"; fi
            if [ "$file" = "$main" ]; then
                REPLY="run: git config --global --unset ${HP_EN_KEY[$i]} (or remove the line from $file)"
                return 0
            fi
            ;;
        command) REPLY="unset the setting in the environment or the command line that sets it"; return 0 ;;
    esac
    REPLY="remove the line from $file (the $scope config)"
    if [ "$scope" = system ]; then REPLY+=", as root"; fi
}
