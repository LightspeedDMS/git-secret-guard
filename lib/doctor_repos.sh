# shellcheck shell=bash disable=SC2153,SC2034

# ^ invariant a repository is at most 31 directories below a root => its .git entry is at find depth 32; the search stays bounded
GSG_DOCTOR_FIND_DEPTH=32
GSG_DOCTOR_MAX_ENTRIES=20000
GSG_DOCTOR_MAX_NOTES=20

DR_FIND=()
# ^ invariant DR_FIND_TREE[i] = the worktree label of DR_FIND[i], empty for the main checkout
DR_FIND_TREE=()
DR_REPO_BAD=0
DR_REPO_HEADER=0
DR_TREE_LABEL=""
declare -gA DR_SEEN=()

# ^ invariant every repo finding goes through here => severity is counted once, text is cleaned, a PROBLEM marks the repo as not covered
# ^ invariant DR_TREE_LABEL names the worktree of a finding => a repeat of the first checkout's finding is dropped, a different one gets the path
doctor_repo_finding() {
    local text="${2//[[:cntrl:]]/?}"
    local base_key current_key
    base_key=$'\t'"$1"$'\t'"$text"
    current_key="$DR_TREE_LABEL$base_key"
    if [[ -n ${DR_SEEN[$current_key]:-} ]]; then return 0; fi
    if [ -n "$DR_TREE_LABEL" ] && [[ -n ${DR_SEEN[$base_key]:-} ]]; then return 0; fi
    DR_SEEN[$current_key]=1
    if [ -n "$DR_TREE_LABEL" ]; then text="worktree ${DR_TREE_LABEL//[[:cntrl:]]/?}: $text"; fi
    case "$1" in
        PROBLEM)
            DR_PROBLEMS=$((DR_PROBLEMS + 1))
            DR_REPO_BAD=1
            ;;
        WARNING) DR_WARNINGS=$((DR_WARNINGS + 1)) ;;
    esac
    DR_FIND+=("$1"$'\t'"$text")
    DR_FIND_TREE+=("$DR_TREE_LABEL")
}

# ^ invariant sets REPLY = the file of a config origin; a relative file origin is relative to the repository the check runs in
doctor_origin_text() {
    case "$1" in
        file:/*) REPLY="${1#file:}" ;;
        file:*) REPLY="$PWD/${1#file:}" ;;
        *) REPLY="$1" ;;
    esac
}

# ^ why a check after rev-parse succeeds, not trust in rev-parse alone; git walks UP from an empty .git and answers for the parent repository
# ^ invariant rc 0 = $1 is the work tree git reports or its git dir is $1/.git; rc 1 writes the reason into rev.err for first_message
doctor_resolves_here() {
    local dir="$1" gitdir="$2" top
    top="$("$GSG_GIT" -C "$dir" rev-parse --show-toplevel 2>/dev/null)" || top=""
    if [ "$top" = "$dir" ] || [ "$gitdir" = "$dir/.git" ]; then return 0; fi
    printf 'the .git entry here is not a git directory (git resolves it to %s)\n' "${top:-$gitdir}" >"$DR_WORK/rev.err"
    return 1
}

# ^ invariant rc 0 = every find stderr line (C locale) said Permission denied or Operation not permitted; a second find names the directories for DR_UNREADABLE
# ^ invariant rc 0 only when FILE holds a line and every line ends in a colon, a space and one of those two phrases
# ^ external macOS find says Operation not permitted for a folder its privacy protection blocks, Linux says Permission denied
doctor_only_permission_denied() {
    local line
    local -a lines=()
    mapfile -t lines <"$1" || return 1
    if [ "${#lines[@]}" -eq 0 ]; then return 1; fi
    for line in "${lines[@]}"; do
        if [[ $line != *": Permission denied" && $line != *": Operation not permitted" ]]; then return 1; fi
    done
}

# ^ external ~/Library holds system data and raises privacy prompts, ~/.Trash is blocked without Full Disk Access and would be a PROBLEM on every run
GSG_DOCTOR_MAC_SKIP=(Library .Trash)

# ^ invariant sets DR_PRUNE = find words skipping each existing $1/<name> of GSG_DOCTOR_MAC_SKIP; only a default macOS run gets any
# ^ why -samefile, not -path; a root holding a glob character would be read as a pattern, and a Library folder deeper down (Unity) must stay searched
doctor_prune_args() {
    local name
    DR_PRUNE=()
    if [ "$DR_DEFAULT_ROOTS" -ne 1 ] || ! brew_is_macos; then return 0; fi
    for name in "${GSG_DOCTOR_MAC_SKIP[@]}"; do
        if [ -d "$1/$name" ]; then DR_PRUNE+=(-samefile "$1/$name" -prune -o); fi
    done
}

# ^ why a second find, not parsing the messages; a path may hold quotes or a newline, NUL-separated names and the shell's own -r and -x tests name it exactly
# ^ external BSD find has no -readable or -executable; the same access(2) answers come from [ -r ] and [ -x ] on each directory find lists
# ^ invariant the second find stops one level above the first (a directory at the depth limit is never opened); any other failure keeps exit 2
doctor_unreadable() {
    local dir rc
    local -a dirs=() bad=()
    doctor_only_permission_denied "$DR_WORK/find.err" || return 1
    doctor_prune_args "$1"
    mapfile -d '' -t dirs < <(LC_ALL=C find "$1" -maxdepth "$((GSG_DOCTOR_FIND_DEPTH - 1))" "${DR_PRUNE[@]}" -name node_modules -type d -prune -o -type d -print0 2>"$DR_WORK/find2.err")
    wait "$!"
    rc=$?
    if [ "$rc" -ne 0 ]; then doctor_only_permission_denied "$DR_WORK/find2.err" || return 1; fi
    for dir in "${dirs[@]}"; do
        if [ ! -r "$dir" ] || [ ! -x "$dir" ]; then bad+=("$dir"); fi
    done
    if [ "${#bad[@]}" -eq 0 ] || [ "${#bad[@]}" -gt "$GSG_DOCTOR_MAX_ENTRIES" ]; then return 1; fi
    for dir in "${bad[@]}"; do
        if [[ -z ${DR_BAD_SEEN[$dir]:-} ]]; then
            DR_BAD_SEEN[$dir]=1
            DR_UNREADABLE+=("$dir")
        fi
    done
}

# ^ invariant puts checkout $1 into DR_KEYS, DR_FIRST, DR_MAIN, DR_LINKED and DR_BROKEN by its git common dir; a repository git cannot open is kept as broken
# ^ why two rev-parse calls, not one two-line answer; a directory name may hold a newline
doctor_classify_dir() {
    local dir="$1" gitdir common key
    if gitdir="$("$GSG_GIT" -C "$dir" rev-parse --path-format=absolute --git-dir 2>"$DR_WORK/rev.err")" \
        && common="$("$GSG_GIT" -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>"$DR_WORK/rev.err")" \
        && doctor_resolves_here "$dir" "$gitdir"; then
        key="$common"
    else
        first_message "$DR_WORK/rev.err"
        key="broken:$dir"
        DR_BROKEN[$key]="${REPLY:-git could not open it}"
        gitdir="" common=""
    fi
    if [[ -z ${DR_FIRST[$key]:-} ]]; then
        DR_KEYS+=("$key")
        DR_FIRST[$key]="$dir"
    fi
    if [ -z "$gitdir" ] || [ "$gitdir" = "$common" ]; then
        DR_MAIN[$key]="$dir"
    else
        DR_LINKED[$key]+="${DR_LINKED[$key]:+$'\n'}$dir"
    fi
}

doctor_discover_reset() {
    DR_KEYS=() DR_SORTED=() DR_UNREADABLE=()
    declare -gA DR_BAD_SEEN=()
    declare -gA DR_FIRST=() DR_MAIN=() DR_LINKED=() DR_BROKEN=() DR_SHOW=() DR_KEY_OF=()
}

# ^ invariant fills DR_SHOW, DR_KEY_OF and DR_SORTED (shown paths, C-locale order) from the classified checkouts in DR_KEYS
doctor_finish_discovery() {
    local key show
    local -A key_of=()
    for key in "${DR_KEYS[@]}"; do
        if [[ -n ${DR_MAIN[$key]:-} ]]; then
            show="${DR_MAIN[$key]}"
        elif [ "${key##*/}" = .git ]; then
            show="${key%/.git}"
        else
            show="$key"
        fi
        DR_SHOW[$key]="$show"
        key_of[$show]="$key"
    done
    for show in "${!key_of[@]}"; do DR_KEY_OF[$show]="${key_of[$show]}"; done
    if [ "${#key_of[@]}" -gt 0 ]; then
        mapfile -d '' -t DR_SORTED < <(printf '%s\0' "${!key_of[@]}" | LC_ALL=C sort -z)
    fi
}

# ^ invariant fills DR_KEYS (one per git common dir) and DR_SORTED (shown paths in order); rc 1 = bound hit or read failed
# ^ invariant a linked worktree is grouped under its main repository by common dir; a repository git cannot open is kept, never skipped
# ^ external wait "$!" after a process substitution = the command's own exit status (probed on bash 5.1.8)
doctor_discover() {
    local root entry dir found=0 rc
    local -A seen=()
    doctor_discover_reset
    for root in "${DR_ROOT_LIST[@]}"; do
        doctor_prune_args "$root"
        while IFS= read -r -d '' entry; do
            found=$((found + 1))
            if [ "$found" -gt "$GSG_DOCTOR_MAX_ENTRIES" ]; then
                printf '%s: more than %s repositories or worktrees under the roots; narrow --roots\n' "$GSG_NAME" "$GSG_DOCTOR_MAX_ENTRIES" >&2
                return 1
            fi
            dir="${entry%/.git}"
            if [[ -n ${seen[$dir]:-} ]]; then continue; fi
            seen[$dir]=1
            doctor_classify_dir "$dir"
        done < <(LC_ALL=C find "$root" -maxdepth "$GSG_DOCTOR_FIND_DEPTH" "${DR_PRUNE[@]}" -name node_modules -type d -prune -o -name .git -prune -print0 2>"$DR_WORK/find.err")
        wait "$!"
        rc=$?
        if [ "$rc" -ne 0 ] && doctor_unreadable "$root"; then rc=0; fi
        if [ "$rc" -ne 0 ]; then
            first_message "$DR_WORK/find.err"
            printf '%s: could not read everything under %s (find exit %s%s); narrow --roots or fix the permissions\n' \
                "$GSG_NAME" "$root" "$rc" "${REPLY:+: ${REPLY//[[:cntrl:]]/?}}" >&2
            return 1
        fi
    done
    doctor_finish_discovery
}

# ^ external hook list line = name, "disabled<TAB>name" (enabled=false) or "event-disabled<TAB>name" (hook.pre-commit.enabled=false); git 2.56
# ^ external a config origin inside the repository is shown relative to it (file:.git/config), see doctor_origin_text
doctor_repo_hook() {
    local line status="" rc i scope origin key want="$DR_HOOK_CMD"
    local -a lines=()
    local -A last_value=() last_scope=() last_origin=()
    mapfile -t lines < <("$GSG_GIT" hook list pre-commit 2>"$DR_WORK/hook.err")
    wait "$!"
    rc=$?
    first_message "$DR_WORK/hook.err"
    # ^ external hook list exit 1 + "no hooks found" on stderr = an empty list, not a failure
    # ^ external git 2.56 exits 128 with "'hook.git-secret-guard.command' must be configured or ... must be removed" when only the command key is gone
    if [ "$rc" -ne 0 ] && [[ $REPLY == *"must be configured or"* ]]; then
        doctor_repo_finding PROBLEM "hook not reached: the global hook config is incomplete (see machine section)"
        return 0
    fi
    if [ "$rc" -ne 0 ] && { [ "$rc" -ne 1 ] || [[ $REPLY != *"no hooks found"* ]]; }; then
        doctor_repo_finding PROBLEM "cannot read the hooks git runs (git hook list pre-commit exit $rc${REPLY:+: $REPLY})"
        return 0
    fi
    for line in "${lines[@]}"; do
        case "$line" in
            git-secret-guard) status=effective ;;
            $'disabled\tgit-secret-guard') status=disabled ;;
            $'event-disabled\tgit-secret-guard') status=event-disabled ;;
        esac
    done
    hp_records config --show-scope --show-origin -z --get-regexp '^hook\.(git-secret-guard\.(enabled|command)|pre-commit\.enabled)$'
    rc=$?
    if [ "$rc" -gt 1 ]; then
        doctor_repo_finding PROBLEM "cannot read the hook config (git config exit $rc${GSG_HP_ERR:+: $GSG_HP_ERR})"
        return 0
    fi
    for ((i = 0; i + 2 < ${#GSG_HP_OUT[@]}; i += 3)); do
        scope="${GSG_HP_OUT[i]}"
        origin="${GSG_HP_OUT[i + 1]}"
        doctor_split_record "${GSG_HP_OUT[i + 2]}"
        last_value[$REC_KEY]="$REC_VALUE" last_scope[$REC_KEY]="$scope" last_origin[$REC_KEY]="$origin"
    done
    case "$status" in
        disabled | event-disabled)
            key=hook.git-secret-guard.enabled
            if [ "$status" = event-disabled ]; then key=hook.pre-commit.enabled; fi
            if [[ -n ${last_origin[$key]:-} ]]; then
                doctor_origin_text "${last_origin[$key]}"
                doctor_repo_finding PROBLEM "disabled in ${last_scope[$key]} config: $key=${last_value[$key]} ($REPLY); remove that key to cover this repository"
            else
                doctor_repo_finding PROBLEM "git hook list pre-commit shows git-secret-guard as $status, and no config key says why"
            fi
            ;;
        effective) ;;
        *) doctor_repo_finding PROBLEM "git-secret-guard is not in 'git hook list pre-commit'; no hook.git-secret-guard.event=pre-commit reaches this repository" ;;
    esac
    key=hook.git-secret-guard.command
    if [[ -n ${last_scope[$key]:-} ]] && [ "${last_scope[$key]}" != global ] && [ "${last_value[$key]}" != "$want" ]; then
        doctor_origin_text "${last_origin[$key]}"
        doctor_repo_finding PROBLEM "command overridden in ${last_scope[$key]} config: $key ($REPLY); remove that key to run the installed hook"
    fi
}

# ^ invariant stderr of the shared hook code => findings; WARNING lines are warnings, the rest take severity $1; at most GSG_DOCTOR_MAX_NOTES shown
doctor_findings_from() {
    local severity="$1" line text n=0
    local -a lines=()
    mapfile -t -n "$((GSG_DOCTOR_MAX_NOTES + 1))" lines <"$2" || return 1
    for line in "${lines[@]}"; do
        n=$((n + 1))
        if [ "$n" -gt "$GSG_DOCTOR_MAX_NOTES" ]; then
            doctor_repo_finding "$severity" "more problems follow; fix these first and run doctor again"
            break
        fi
        text="${line#"$GSG_NAME: "}"
        if [[ $text == "WARNING: "* ]]; then
            doctor_repo_finding WARNING "${text#WARNING: }"
        else
            doctor_repo_finding "$severity" "$text"
        fi
    done
}

# ^ invariant a file the hook blocks on = PROBLEM here too; exempt_head_blob rc 1 = absent, 2 = git read error, 3 = not a regular file
doctor_repo_ignore() {
    local blob="$DR_WORK/ignore-head" rows rc
    exempt_head_blob "$GSG_IGNORE_FILE" "$blob"
    rc=$?
    case "$rc" in
        0) ;;
        1) return 0 ;;
        3)
            doctor_repo_finding PROBLEM "$GSG_IGNORE_FILE at HEAD must be a regular file (a symlink or directory is refused); every commit in this repository is blocked"
            return 0
            ;;
        *)
            doctor_repo_finding PROBLEM "cannot read $GSG_IGNORE_FILE at HEAD (doctor never fetches a missing object${EXEMPT_GIT_ERR:+; git said: $EXEMPT_GIT_ERR}); every commit in this repository is blocked unless the file can be read"
            return 0
            ;;
    esac
    if ! rows="$(scan_ignore_parse "$blob" 2>"$DR_WORK/ignore.err")"; then
        doctor_findings_from PROBLEM "$DR_WORK/ignore.err"
        doctor_repo_finding PROBLEM "$GSG_IGNORE_FILE at HEAD is invalid; every commit in this repository is blocked until it is fixed (repair it with git commit --no-verify)"
        return 0
    fi
    if [ -z "$rows" ]; then return 0; fi
    GSG_EXCLUDES=()
    if ! exempt_warn_rows "$DR_WORK/probe" "$rows" 2>"$DR_WORK/warn.err"; then
        doctor_findings_from PROBLEM "$DR_WORK/warn.err"
        return 0
    fi
    doctor_findings_from WARNING "$DR_WORK/warn.err"
}

# ^ invariant betterleaks_config_preflight rc 0 = probe reported, 2 = built-in rules off, 1 = does not load; one work dir per repo
# ^ coupled with lib/exempt.sh:_load_gitleaks_files; the same pre-flight and the same sentence
doctor_repo_betterleaks() {
    local conf="$DR_WORK/repo-gitleaks.toml" work="$DR_WORK/pf-$DR_REPO_TOTAL" rc limit
    exempt_head_blob .gitleaks.toml "$conf"
    rc=$?
    case "$rc" in
        0) ;;
        1) return 0 ;;
        3)
            doctor_repo_finding PROBLEM ".gitleaks.toml at HEAD must be a regular file (a symlink or directory is refused); every commit in this repository is blocked"
            return 0
            ;;
        *)
            doctor_repo_finding PROBLEM "cannot read .gitleaks.toml at HEAD${EXEMPT_GIT_ERR:+ (git said: $EXEMPT_GIT_ERR)}; every commit in this repository is blocked"
            return 0
            ;;
    esac
    if [ "$DR_BETTERLEAKS_OK" -ne 1 ]; then
        doctor_repo_finding WARNING ".gitleaks.toml at HEAD was not checked: betterleaks or timeout is unusable (see the machine section)"
        return 0
    fi
    if ! mkdir -p -- "$work"; then
        doctor_repo_finding PROBLEM "cannot create a work directory to check .gitleaks.toml at HEAD"
        return 0
    fi
    # ^ why the smaller of the two limits, not SCAN_TIMEOUT_SECONDS alone; doctor visits every repository, the hook serves one commit
    limit="$SCAN_TIMEOUT_SECONDS"
    if [ "$DR_LIMIT" -lt "$limit" ]; then limit="$DR_LIMIT"; fi
    betterleaks_config_preflight "$conf" "$work" "$limit" 2>"$DR_WORK/pf.err"
    rc=$?
    case "$rc" in
        0) ;;
        2) doctor_repo_finding WARNING "$GSG_MSG_BUILTIN_RULES_OFF" ;;
        *)
            first_message "$DR_WORK/pf.err"
            # ^ coupled with lib/exempt.sh:betterleaks_config_preflight; its timeout sentence starts with "betterleaks did not finish loading"
            if [ "$limit" -lt "$SCAN_TIMEOUT_SECONDS" ] && [[ $REPLY == "betterleaks did not finish loading"* ]]; then
                doctor_repo_finding PROBLEM "betterleaks timed out after ${limit}s loading .gitleaks.toml at HEAD (doctor's limit; the hook allows ${SCAN_TIMEOUT_SECONDS}s), so doctor could not judge it"
            else
                doctor_findings_from PROBLEM "$DR_WORK/pf.err"
            fi
            ;;
    esac
}

# ^ external pre-commit install writes "File generated by pre-commit" as line 2 of its hook (pre-commit 4.3.0)
# ^ invariant info never changes the exit status; global and system core.hooksPath belong to the machine section
# ^ invariant $1 = the absolute git common dir, the discovery key of an openable repo
doctor_repo_info() {
    local common="$1" line i rc installed=0 scope origin
    local shim="$common/hooks/pre-commit"
    local -a head=()
    if [ -f .pre-commit-config.yaml ]; then
        if [ -f "$shim" ]; then
            mapfile -t -n 5 head <"$shim" || head=()
            for line in "${head[@]}"; do
                if [ "$line" = "# File generated by pre-commit: https://pre-commit.com" ]; then installed=1; fi
            done
        fi
        if [ "$installed" -eq 0 ]; then
            doctor_repo_finding info ".pre-commit-config.yaml is present but $shim is not the pre-commit framework's hook (pre-commit install not run)"
        fi
    fi
    hp_records config --show-scope --show-origin -z --get-regexp '^core\.hookspath$'
    rc=$?
    if [ "$rc" -gt 1 ]; then
        doctor_repo_finding PROBLEM "cannot read core.hooksPath (git config exit $rc${GSG_HP_ERR:+: $GSG_HP_ERR})"
        return 0
    fi
    for ((i = 0; i + 2 < ${#GSG_HP_OUT[@]}; i += 3)); do
        scope="${GSG_HP_OUT[i]}"
        origin="${GSG_HP_OUT[i + 1]}"
        if [ "$scope" = global ] || [ "$scope" = system ]; then continue; fi
        doctor_split_record "${GSG_HP_OUT[i + 2]}"
        doctor_origin_text "$origin"
        origin="$REPLY"
        trunc_text "$REC_VALUE" 120
        doctor_repo_finding info "core.hooksPath=$REPLY in $scope config ($origin); harmless, config hooks run whatever it says"
    done
}

# ^ why the hook check runs in every worktree, not only the main one; extensions.worktreeConfig gives each checkout a config.worktree layer
# ^ invariant the first checkout checked is reported plain, another one only when its answer differs; every iteration ends back in $1
doctor_check_worktrees() {
    local run="$1" key="$2" tree
    local -a trees=()
    doctor_repo_hook
    if [[ -n ${DR_LINKED[$key]:-} ]]; then mapfile -t trees <<<"${DR_LINKED[$key]}"; fi
    for tree in "${trees[@]}"; do
        if [ "$tree" = "$run" ]; then continue; fi
        DR_TREE_LABEL="$tree"
        if cd -- "$tree"; then
            doctor_repo_hook
        else
            doctor_repo_finding PROBLEM "cannot be entered, so its hook config was not checked"
        fi
        DR_TREE_LABEL=""
        cd -- "$run" || return 1
    done
}

doctor_check_repo() {
    local key="$1" run
    DR_FIND=() DR_FIND_TREE=() DR_SEEN=() DR_TREE_LABEL=""
    if [[ -n ${DR_BROKEN[$key]:-} ]]; then
        doctor_repo_finding PROBLEM "cannot be inspected: ${DR_BROKEN[$key]}"
        return 0
    fi
    run="${DR_MAIN[$key]:-${DR_FIRST[$key]}}"
    if ! cd -- "$run"; then
        doctor_repo_finding PROBLEM "cannot enter $run"
        return 0
    fi
    doctor_check_worktrees "$run" "$key" || {
        doctor_repo_finding PROBLEM "cannot return to $run"
        return 0
    }
    doctor_repo_ignore
    doctor_repo_betterleaks
    doctor_repo_info "$key"
}

doctor_print_repo() {
    local show="$1" key="$2" f joined
    local -a trees=()
    printf '  %s\n' "${show//[[:cntrl:]]/?}"
    if [[ -n ${DR_LINKED[$key]:-} ]]; then
        mapfile -t trees <<<"${DR_LINKED[$key]}"
        printf -v joined '%s, ' "${trees[@]//[[:cntrl:]]/?}"
        printf '    worktrees: %s\n' "${joined%, }"
    fi
    for f in "${DR_FIND[@]}"; do
        printf '    %-8s %s\n' "${f%%$'\t'*}" "${f#*$'\t'}"
    done
}

# ^ security each git call of the repository phase runs under timeout via a shim first on PATH and named by GSG_GIT => a hung repository becomes a finding
# ^ why a shim script, not a git() function; hp_records and the shared exempt.sh code call git by path and by name, and the hook must not learn about doctor
# ^ invariant the shim prints "timed out after Ns" on exit 124 or 137 and, when timeout or DOCTOR_TIMEOUT_SECONDS is unusable, runs no git at all (exit 125)
doctor_bound_git() {
    local real="$GSG_GIT" shim="$DR_WORK/bin/git"
    mkdir -p -- "$DR_WORK/bin" || return 1
    if [ "$DR_TIMEOUT_OK" -eq 1 ] && [ -n "$DR_LIMIT" ]; then
        # shellcheck disable=SC2016
        {
            printf '#!/usr/bin/env bash\n'
            # ^ hazard --foreground here => a timed-out git leaves its own children running; test:test_a_timed_out_doctor_run_leaves_no_process_behind
            # ^ why no --foreground, not the hook adapters' choice; doctor never needs the tty and timeout's own group is signalled whole
            printf '%q -k 5 %q %q "$@"\n' "$TIMEOUT_BIN" "$DR_LIMIT" "$real"
            printf 'rc=$?\nif [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then echo "timed out after %ss" >&2; fi\nexit "$rc"\n' "$DR_LIMIT"
        } >"$shim" || return 1
    else
        printf '#!/usr/bin/env bash\necho "git was not run: timeout or DOCTOR_TIMEOUT_SECONDS is unusable (see machine section)" >&2\nexit 125\n' >"$shim" || return 1
    fi
    chmod 755 -- "$shim" || return 1
    GSG_GIT="$shim"
    export PATH="$DR_WORK/bin:$PATH"
}

# ^ invariant checks every repository in DR_SORTED, records its PROBLEMs for the findings file and prints those with findings (PROBLEMs only in recheck mode)
doctor_repo_loop() {
    local show key
    for show in "${DR_SORTED[@]}"; do
        key="${DR_KEY_OF[$show]}"
        DR_REPO_TOTAL=$((DR_REPO_TOTAL + 1))
        DR_REPO_BAD=0
        doctor_check_repo "$key"
        if [ "$DR_REPO_BAD" -eq 0 ]; then DR_REPO_COVERED=$((DR_REPO_COVERED + 1)); fi
        doctor_rec_collect "$show"
        if [ "$DR_RECHECK" -eq 1 ]; then doctor_keep_problems_only; fi
        if [ "${#DR_FIND[@]}" -eq 0 ]; then continue; fi
        if [ "$DR_REPO_HEADER" -eq 0 ]; then
            printf 'repos with findings:\n'
            DR_REPO_HEADER=1
        fi
        doctor_print_repo "$show" "$key"
    done
}

doctor_repos() {
    local dir queued
    doctor_bound_git || return 1
    doctor_discover || return 1
    if [ "${#DR_UNREADABLE[@]}" -gt 0 ]; then
        printf 'not searched:\n'
        queued="${#DR_REC_NEW[@]}"
        for dir in "${DR_UNREADABLE[@]}"; do
            doctor_machine_line PROBLEM "cannot read $dir; repositories below it are not checked"
        done
        # ^ why unreadable directories stay out of the record, not in it; only discovery finds one and a recheck never discovers
        DR_REC_NEW=("${DR_REC_NEW[@]:0:queued}")
    fi
    doctor_repo_loop
}
