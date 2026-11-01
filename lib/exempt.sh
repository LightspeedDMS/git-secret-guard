# shellcheck shell=bash

GSG_IGNORE_FILE=.secret-scan-ignore
GSG_IGNORE_MAX_LINES=1000
# ^ coupled with lib/doctor_repos.sh:doctor_repo_gitleaks; the hook and doctor print this sentence for gitleaks_config_preflight rc 2
GSG_MSG_BUILTIN_RULES_OFF='with .gitleaks.toml at HEAD, gitleaks does not detect its own built-in rules (e.g. AWS access keys): either [extend] useDefault = true is missing, or an allowlist or disabledRules turns them off; trufflehog still runs'

# ^ invariant scan_ignore_parse is the only reader of the .secret-scan-ignore format => hook and doctor share one validation

_trim_ws() {
    REPLY=""
    if [[ $1 =~ ^[[:space:]]*(.*[^[:space:]])?[[:space:]]*$ ]]; then
        REPLY="${BASH_REMATCH[1]}"
    fi
}

# ^ invariant stdout carries only "LINE<TAB>pattern<TAB>as-written" rows => every complaint goes to stderr with the hook prefix
# ^ invariant as-written keeps a leading / or ./ and never holds a tab or control character => the catch-all warning quotes the user's own text
scan_ignore_parse() {
    local file="$1" label="${2:-$GSG_IGNORE_FILE}" line pat orig reason n=0 bad=0
    local -a lines=()
    mapfile -t -n "$((GSG_IGNORE_MAX_LINES + 1))" lines <"$file" || return 1
    if [ "${#lines[@]}" -gt "$GSG_IGNORE_MAX_LINES" ]; then
        printf '%s: %s has more than %s lines; split the exemptions or use broader patterns\n' "$GSG_NAME" "$label" "$GSG_IGNORE_MAX_LINES" >&2
        return 1
    fi
    for line in "${lines[@]}"; do
        n=$((n + 1))
        line="${line%$'\r'}"
        _trim_ws "$line"
        line="$REPLY"
        case "$line" in '' | '#'*) continue ;; esac
        pat="${line%%[[:space:]]#*}"
        reason=""
        if [ "$pat" != "$line" ]; then
            reason="${line#"$pat"}"
            reason="${reason#*#}"
        fi
        if [[ ! $reason =~ [^[:space:]#] ]]; then
            printf '%s: %s line %s: a reason is required, written as "pattern  # why it is safe to skip"\n' "$GSG_NAME" "$label" "$n" >&2
            bad=1
            continue
        fi
        _trim_ws "$pat"
        pat="$REPLY"
        orig="$pat"
        # ^ why strip a leading slash, not pass it; git rejects "/x" as outside the repository, and gitignore users mean "from the root"
        while [[ $pat == /* || $pat == ./* ]]; do
            pat="${pat#/}"
            pat="${pat#./}"
        done
        if [ -z "$pat" ] || [[ $pat == *[[:cntrl:]]* ]]; then
            printf '%s: %s line %s: the pattern is empty or holds a control character\n' "$GSG_NAME" "$label" "$n" >&2
            bad=1
            continue
        fi
        if [[ "/$pat/" == */../* ]]; then
            printf '%s: %s line %s: a ".." component cannot match inside the repository\n' "$GSG_NAME" "$label" "$n" >&2
            bad=1
            continue
        fi
        printf '%s\t%s\t%s\n' "$n" "$pat" "$orig"
    done
    return "$bad"
}

# ^ security only HEAD counts, never the index or the work tree => a commit cannot exempt itself; test:test_head_blob_is_read_from_the_commit_only
# ^ why ls-tree with a mode check, not cat-file -t => a symlink reads as its target text and any cat-file failure looked like an absent file
# ^ invariant rc 1 = no HEAD or no entry => caller applies no exemption; rc 2 = git read error, rc 3 = not a regular file (100644/100755) => caller blocks
exempt_head_blob() {
    local path="$1" dest="$2" rc entry mode type
    EXEMPT_GIT_ERR=""
    git rev-parse -q --verify 'HEAD^{commit}' >/dev/null 2>&1
    rc=$?
    if [ "$rc" -eq 1 ]; then return 1; fi
    if [ "$rc" -ne 0 ]; then return 2; fi
    entry="$(git ls-tree --full-tree HEAD -- "$path" 2>"$dest.err")" || {
        _head_blob_failed "$dest.err"
        return 2
    }
    if [ -z "$entry" ]; then return 1; fi
    read -r mode type _ <<<"$entry"
    case "$mode:$type" in 100644:blob | 100755:blob) ;; *) return 3 ;; esac
    git cat-file blob "HEAD:$path" >"$dest" 2>"$dest.err" || {
        _head_blob_failed "$dest.err"
        return 2
    }
}

# ^ invariant sets EXEMPT_GIT_ERR = git's first message, sanitized and cut => callers fold it into their own line; git's raw stderr never shows
_head_blob_failed() {
    first_message "$1"
    EXEMPT_GIT_ERR="$REPLY"
}

# ^ why top magic, not the story's plain :(exclude,glob); without it git aborts on "/x" and "../x", and relative patterns would depend on the cwd
# ^ coupled the pathspec form with lib/extract.sh callers; the hook, the counts and the probe must all build it here
scan_ignore_pathspec() {
    printf ':(exclude,top,glob)%s' "$1"
}

GSG_EXCLUDES=()
GSG_WHOLE_WARNED=0
GSG_IGNORE_ONLY=":(top,literal)$GSG_IGNORE_FILE"
GSG_IGNORE_LEFT_OUT=":(exclude,top,literal)$GSG_IGNORE_FILE"

_head_file() {
    local name="$1" dest="$2" rc
    exempt_head_blob "$name" "$dest"
    rc=$?
    if [ "$rc" -eq 2 ]; then
        printf '%s: cannot read %s at HEAD%s; commit blocked, nothing was scanned.\n' "$GSG_NAME" "$name" "${EXEMPT_GIT_ERR:+ (git said: $EXEMPT_GIT_ERR)}" >&2
    elif [ "$rc" -eq 3 ]; then
        printf '%s: %s at HEAD must be a regular file (a symlink or directory is refused); commit blocked, nothing was scanned.\n' "$GSG_NAME" "$name" >&2
    fi
    return "$rc"
}

# ^ invariant exempt_load fills GSG_EXCLUDES and the work dir copies of HEAD's gitleaks files; rc 1 = block, message already printed
exempt_load() {
    local work="$1"
    GSG_EXCLUDES=()
    _load_ignore_file "$work" || return 1
    _load_gitleaks_files "$work"
}

_load_ignore_file() {
    local work="$1" blob="$1/ignore-head" rows rc
    _head_file "$GSG_IGNORE_FILE" "$blob"
    rc=$?
    if [ "$rc" -ge 2 ]; then return 1; fi
    if [ "$rc" -eq 1 ]; then return 0; fi
    if ! rows="$(scan_ignore_parse "$blob")"; then
        printf '%s: %s at HEAD is invalid (see above); commit blocked, nothing was scanned.\n' "$GSG_NAME" "$GSG_IGNORE_FILE" >&2
        return 1
    fi
    if [ -z "$rows" ]; then return 0; fi
    exempt_warn_rows "$work/probe" "$rows"
}

# ^ invariant appends one exclude pathspec per row to GSG_EXCLUDES (caller resets it) and prints catch-all and union warnings; rc 1 = probe failed
# ^ coupled with lib/doctor_repos.sh:doctor_repo_ignore; the hook and doctor must judge the same rows the same way
exempt_warn_rows() {
    local probe="$1" rows="$2" n pat orig
    GSG_WHOLE_WARNED=0
    while IFS=$'\t' read -r n pat orig; do
        GSG_EXCLUDES+=("$(scan_ignore_pathspec "$pat")")
        _warn_if_catch_all "$probe" "$n" "$pat" "$orig" || return 1
    done <<<"$rows"
    if [ "$GSG_WHOLE_WARNED" -eq 0 ]; then _warn_if_union_covers_tree "${GSG_EXCLUDES[@]}"; fi
}

# ^ invariant an applied repo gitleaks file is always announced in one line; exemptions are never silent
_load_gitleaks_files() {
    local work="$1" rc
    _head_file .gitleaks.toml "$work/$GSG_REPO_GITLEAKS_TOML"
    rc=$?
    if [ "$rc" -ge 2 ]; then return 1; fi
    if [ "$rc" -eq 0 ]; then
        gitleaks_config_preflight "$work/$GSG_REPO_GITLEAKS_TOML" "$work" "${SCAN_TIMEOUT_SECONDS:-}"
        rc=$?
        if [ "$rc" -eq 1 ]; then return 1; fi
        printf '%s: using .gitleaks.toml from HEAD (this repository'"'"'s gitleaks rules and allowlists apply)\n' "$GSG_NAME" >&2
        if [ "$rc" -eq 2 ]; then
            printf '%s: WARNING: %s\n' "$GSG_NAME" "$GSG_MSG_BUILTIN_RULES_OFF" >&2
        fi
    fi
    _head_file .gitleaksignore "$work/$GSG_REPO_GITLEAKS_IGNORE"
    rc=$?
    if [ "$rc" -ge 2 ]; then return 1; fi
    if [ "$rc" -eq 0 ]; then
        printf '%s: using .gitleaksignore from HEAD (its fingerprints suppress gitleaks findings)\n' "$GSG_NAME" >&2
    fi
    return 0
}

# ^ invariant a catch-all warns on every commit => the check runs before any early exit
_warn_if_catch_all() {
    local probe="$1" n="$2" pat="$3" orig="$4" scope what
    # ^ perf a pattern without * ? [ is a path prefix and cannot cover every probe; skipping it saves one git diff per pattern (1000 patterns = 5 s)
    case "$pat" in *[*?[]*) ;; *) return 0 ;; esac
    if [ ! -d "$probe/.git" ]; then
        scan_ignore_probe_init "$probe" || {
            printf '%s: cannot build the pattern probe repository; commit blocked, nothing was scanned.\n' "$GSG_NAME" >&2
            return 1
        }
    fi
    scope="$(scan_ignore_scope "$probe" "$pat")" || {
        printf '%s: cannot evaluate %s line %s with git; commit blocked, nothing was scanned.\n' "$GSG_NAME" "$GSG_IGNORE_FILE" "$n" >&2
        return 1
    }
    case "$scope" in
        whole) what="the whole repository" GSG_WHOLE_WARNED=1 ;;
        top) what="every top-level file (git's glob '*' does not cross '/'; '**' covers the whole repository)" ;;
        nested) what="every file below the top level" ;;
        *) return 0 ;;
    esac
    trunc_text "$orig" 60
    printf "%s: WARNING: %s line %s (pattern '%s') exempts %s from scanning\n" "$GSG_NAME" "$GSG_IGNORE_FILE" "$n" "$REPLY" "$what" >&2
}

# ^ why two passes, not one diff; pathspec excludes cannot be re-included => the ignore file gets its own diff and is scanned whatever a pattern says
# ^ coupled with lib/extract.sh:staged_diff, extract_added_lines; the hook sources both
exempt_extract_tree() {
    local dir="$1"
    shift
    if [ "$#" -eq 0 ]; then
        staged_diff | extract_added_lines "$dir"
        return
    fi
    staged_diff -- "$GSG_IGNORE_LEFT_OUT" "$@" | extract_added_lines "$dir" || return 1
    staged_diff -- "$GSG_IGNORE_ONLY" | extract_added_lines "$dir"
}

# ^ security fragments, never one literal => no credential-looking value in the tree; test:test_the_project_tree_holds_no_credential_looking_literals
# ^ external only gitleaks' built-in aws-access-token rule detects this shape (8.30.1); a bare key ID is enough, no key= context needed
gitleaks_probe_secret() {
    printf '%s%s' "AKI""A" "Q7XK2MWB4HZ5NR3T"
}

# ^ external the probe name has no extension => an ordinary allowlist misses it; a global allowlist matching it makes the warning true
GSG_PROBE_FILE=gsg-probe-builtin-rule

# ^ why a real gitleaks run, not a regex over the TOML; no line scan is sound against TOML spellings (case, strings, escapes, inline and dotted tables)
# ^ security cwd is an EMPTY dir, the probe dir is the target => a relative extend.path cannot open; test:test_real_every_spelling_of_extend_path_is_refused
# ^ hazard an absolute extend.path to an existing file still loads => accepted, it is local config reviewed at HEAD
gitleaks_config_preflight() {
    local conf="$1" base="$2/preflight" log="$2/preflight.log" limit="${3:-}" rc line msg=""
    local empty="$base/empty" probe="$base/probe" problem
    local -a lines=()
    if [[ ! $limit =~ ^[1-9][0-9]*$ ]]; then
        printf '%s: gitleaks_config_preflight needs a timeout in seconds (a positive integer); commit blocked, nothing was scanned.\n' "$GSG_NAME" >&2
        return 1
    fi
    if problem="$(tool_unusable timeout "${TIMEOUT_BIN:-}")"; then
        printf '%s: %s; commit blocked, nothing was scanned.\n' "$GSG_NAME" "$problem" >&2
        return 1
    fi
    mkdir -p -- "$empty" "$probe" || return 1
    { gitleaks_probe_secret && printf '\n'; } >"$probe/$GSG_PROBE_FILE" || return 1
    # ^ why the probe shares this run, not a third gitleaks process; load check and built-in-rule check cost one process start
    (
        cd -- "$empty" || exit 2
        exec "$TIMEOUT_BIN" --foreground -k 5 "$limit" "$GITLEAKS_BIN" dir "$probe" --config "$conf" --no-banner --no-color --redact \
            --exit-code "$GSG_GITLEAKS_LEAK_RC" >/dev/null 2>"$log"
    )
    rc=$?
    # ^ invariant rc 0 = probe reported; rc 2 = loads, probe not reported (caller warns); rc 1 = block; a repo rule matching the probe counts as reported
    if [ "$rc" -eq "$GSG_GITLEAKS_LEAK_RC" ]; then return 0; fi
    if [ "$rc" -eq 0 ]; then return 2; fi
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]; then
        printf '%s: gitleaks did not finish loading .gitleaks.toml at HEAD within %ss; commit blocked, nothing was scanned.\n' "$GSG_NAME" "$limit" >&2
        return 1
    fi
    mapfile -t -n 200 lines <"$log" || lines=()
    for line in "${lines[@]}"; do
        if [[ $line == *$'\e'* ]]; then line="$(strip_ansi "$line")"; fi
        if [[ $line =~ ^[^[:space:]]+[[:space:]]+(ERR|FTL)[[:space:]]+(.*)$ ]]; then
            msg="$(msg_words "${BASH_REMATCH[2]}")"
            break
        fi
    done
    msg="${msg//[^[:print:]]/?}"
    trunc_text "$msg" 200
    printf '%s: .gitleaks.toml at HEAD does not load on its own (gitleaks said: %s); a base config reached through [extend] path must be inlined; commit blocked, nothing was scanned.\n' \
        "$GSG_NAME" "$REPLY" >&2
    return 1
}

# ^ invariant the ignore file is never counted as excluded; it is always scanned
# ^ invariant a commit with every file excluded is announced; nothing about it is silent
exempt_report_exclusions() {
    local all kept
    all="$(staged_added_file_count -- "$GSG_IGNORE_LEFT_OUT")" || return 1
    kept="$(staged_added_file_count -- "$GSG_IGNORE_LEFT_OUT" "$@")" || return 1
    if [ "$all" -le "$kept" ]; then return 0; fi
    printf '%s: %s staged file(s) excluded by %s\n' "$GSG_NAME" "$((all - kept))" "$GSG_IGNORE_FILE" >&2
    if [ "$kept" -eq 0 ]; then
        printf '%s: WARNING: every staged file with added lines is excluded by %s; nothing else in this commit was scanned\n' "$GSG_NAME" "$GSG_IGNORE_FILE" >&2
    fi
}

# ^ invariant every pathspec passed here is an exclude => the count is the files remaining after exclusion (0 = all exempt)
_index_count() {
    git ls-files -z --cached -- "$@" | tr -cd '\0' | wc -c
}

# ^ why compare the real index, not more probes; no probe set can cover shapes like "src/** lib/**" or "**/[!a]*", the tracked tree is the ground truth
# ^ invariant the ignore file is left out of both counts => it never makes "everything" false; it is always scanned
_warn_if_union_covers_tree() {
    local tracked remaining
    if ! tracked="$(_index_count "$GSG_IGNORE_LEFT_OUT")"; then
        printf '%s: cannot list the tracked files with git; commit blocked, nothing was scanned.\n' "$GSG_NAME" >&2
        return 1
    fi
    if ! remaining="$(_index_count "$GSG_IGNORE_LEFT_OUT" "$@")"; then
        printf '%s: cannot list the tracked files with git; commit blocked, nothing was scanned.\n' "$GSG_NAME" >&2
        return 1
    fi
    if [ "$tracked" -gt 0 ] && [ "$remaining" -eq 0 ]; then
        printf '%s: WARNING: the patterns in %s together exempt every tracked file; only %s itself is scanned\n' "$GSG_NAME" "$GSG_IGNORE_FILE" "$GSG_IGNORE_FILE" >&2
    fi
}

# ^ external git glob pathspecs, "*" does not cross "/" and "**" does => "*" excludes only top-level names (probed on git 2.56)
GSG_PROBE_TOP=(a a.txt .hidden UPPER.TXT 'x y.txt' -dash a.b.c '~tilde' 'ünï.txt')
GSG_PROBE_NESTED=(d/a d/a.txt .d/.hidden d/e/f/g/h.txt 'src/x y.txt' .github/workflows/ci.yml node_modules/x/index.js 'ünï/ƒ.txt' d/UPPER)
GSG_LOCAL_ENV=()

# ^ security GIT_DIR and GIT_INDEX_FILE are set during pre-commit => unset for the probe, else it would read the real index
_probe_git() {
    local dir="$1" v vars
    shift
    if [ "${#GSG_LOCAL_ENV[@]}" -eq 0 ]; then
        vars="$(git rev-parse --local-env-vars)" || return 1
        while IFS= read -r v; do GSG_LOCAL_ENV+=(-u "$v"); done <<<"$vars"
    fi
    env "${GSG_LOCAL_ENV[@]}" git -c core.quotePath=false -C "$dir" "$@"
}

scan_ignore_probe_init() {
    local dir="$1" p
    mkdir -p -- "$dir" || return 1
    _probe_git "$dir" init -q --template= . || return 1
    for p in "${GSG_PROBE_TOP[@]}" "${GSG_PROBE_NESTED[@]}"; do
        case "$p" in */*) mkdir -p -- "$dir/${p%/*}" || return 1 ;; esac
        : >"$dir/$p" || return 1
    done
    _probe_git "$dir" add -f -- . || return 1
}

# ^ invariant prints whole (no probe left), top (only nested left), nested (only top-level left) or none
scan_ignore_scope() {
    local dir="$1" pat="$2" listing f nt=0 nn=0
    [ -d "$dir/.git" ] || return 2
    listing="$(_probe_git "$dir" diff --cached --name-only -- "$(scan_ignore_pathspec "$pat")")" || return 2
    while IFS= read -r f; do
        case "$f" in '') ;; */*) nn=$((nn + 1)) ;; *) nt=$((nt + 1)) ;; esac
    done <<<"$listing"
    if [ $((nt + nn)) -eq 0 ]; then
        printf 'whole\n'
    elif [ "$nt" -eq 0 ]; then
        printf 'top\n'
    elif [ "$nn" -eq 0 ]; then
        printf 'nested\n'
    else
        printf 'none\n'
    fi
}
