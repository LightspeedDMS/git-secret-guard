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
