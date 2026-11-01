# shellcheck shell=bash

GSG_GITLEAKS_RENAMED=.gitleaksignore.gsg-committed
GSG_GITLEAKS_LOG_LINES=5000
GSG_GITLEAKS_SHOWN_MAX=5

# shellcheck disable=SC2016
scan_gitleaks() {
    local scan_dir="$1" out="$2"
    local rows="$out/gitleaks.rows" errs="$out/gitleaks.errors"
    local report="$out/gitleaks.json" log="$out/gitleaks.log"
    local conf="$out/gitleaks.toml" ignore_dir="$out/gitleaks-ignore"
    local rc problem nrows gl_tree
    # ^ invariant out and scan dirs absolute => the cd below cannot invalidate the config/report/ignore paths
    case "$out" in /*) ;; *) return 1 ;; esac
    case "$scan_dir" in /*) ;; *) return 1 ;; esac
    [ -d "$scan_dir" ] || return 1
    : >"$rows" && : >"$errs" || return 1

    if problem="$(tool_unusable gitleaks "${GITLEAKS_BIN:-}")" || problem="$(tool_unusable timeout "${TIMEOUT_BIN:-}")"; then
        printf 'gitleaks: %s; nothing was scanned\n' "$problem" >"$errs" || return 1
        return 0
    fi

    # ^ security explicit --config and --gitleaks-ignore-path => a commit cannot mute itself with its own .gitleaks.toml or .gitleaksignore
    printf '[extend]\nuseDefault = true\n' >"$conf" && mkdir -p -- "$ignore_dir" || return 1

    # ^ security only copies the hook took from HEAD are honored; the staged or working-tree versions never reach --config / --gitleaks-ignore-path
    if [ -f "$out/$GSG_REPO_GITLEAKS_TOML" ]; then conf="$out/$GSG_REPO_GITLEAKS_TOML"; fi
    if [ -f "$out/$GSG_REPO_GITLEAKS_IGNORE" ]; then
        cp -- "$out/$GSG_REPO_GITLEAKS_IGNORE" "$ignore_dir/.gitleaksignore" || return 1
    fi

    # ^ security gitleaks honors <target root>/.gitleaksignore whatever --gitleaks-ignore-path says (probed on 8.30.1) => the commit could mute itself
    # ^ why rename in a copy, not delete; the added lines of the file stay scanned
    # ^ external gitleaks reads only the target root .gitleaksignore, nested ones are ignored (probed on 8.30.1)
    gl_tree="$scan_dir"
    if [ -e "$scan_dir/.gitleaksignore" ]; then
        gl_tree="$out/gitleaks-tree"
        cp -a -- "$scan_dir" "$gl_tree" || return 1
        if [ -e "$gl_tree/$GSG_GITLEAKS_RENAMED" ]; then return 1; fi
        mv -- "$gl_tree/.gitleaksignore" "$gl_tree/$GSG_GITLEAKS_RENAMED" || return 1
    fi

    # ^ why cwd = scan dir with path ".", not an absolute path; fingerprints become "src/a.txt:rule:N", usable in a committed .gitleaksignore
    (
        cd -- "$gl_tree" || exit 1
        exec "$TIMEOUT_BIN" --foreground -k 5 "$SCAN_TIMEOUT_SECONDS" "$GITLEAKS_BIN" dir . \
            --config "$conf" --gitleaks-ignore-path "$ignore_dir" --redact \
            --report-format json --report-path "$report" --exit-code "$GSG_GITLEAKS_LEAK_RC" \
            --no-banner --no-color >/dev/null 2>"$log"
    )
    rc=$?

    if [ "$rc" -eq 124 ]; then
        printf 'gitleaks: timed out after %ss; the scan did not complete\n' "$SCAN_TIMEOUT_SECONDS" >>"$errs" || return 1
    elif [ "$rc" -ne 0 ] && [ "$rc" -ne "$GSG_GITLEAKS_LEAK_RC" ]; then
        printf 'gitleaks: scan failed (exit %s)\n' "$rc" >>"$errs" || return 1
    elif [ ! -s "$report" ]; then
        printf 'gitleaks: no report was written (exit %s); failing closed\n' "$rc" >>"$errs" || return 1
    # ^ security jq stderr dropped => parse errors quote the input
    elif ! "$JQ_BIN" -r --arg prefix "$scan_dir/" --arg renamed "$GSG_GITLEAKS_RENAMED" "$GSG_JQ_CLEAN"'
            (if type == "array" then .[] else error("not an array") end)
            | (if type == "object" then . else error("not an object") end)
            | (.StartLine // 0) as $line
            | ["gitleaks", (.RuleID // "?" | clean), "finding",
               (.File // "?" | ltrimstr($prefix) | (if . == $renamed then ".gitleaksignore" else . end) | clean),
               (if ($line | type) == "number" and $line >= 1 then ($line | floor | tostring) else "?" end)]
            | @tsv' "$report" >"$rows" 2>/dev/null; then
        : >"$rows"
        printf 'gitleaks: could not parse its report; failing closed\n' >>"$errs" || return 1
    else
        nrows="$(wc -l <"$rows")" || return 1
        if [ "$rc" -eq "$GSG_GITLEAKS_LEAK_RC" ] && [ "$nrows" -eq 0 ]; then
            printf 'gitleaks: reported leaks (exit %s) but its report holds none\n' "$rc" >>"$errs" || return 1
        fi
    fi

    gitleaks_log_errors "$log" >>"$errs" || return 1
    return 0
}

# ^ hazard 8.30.1 exits 0 or 42 after "WRN skipping file" (unreadable input) => skipped files are scan errors
# ^ invariant output of this function is appended to the errors file; any line printed here blocks the commit via report_results
gitleaks_log_errors() {
    local log="$1" line msg shown=0
    local -a lines=()
    mapfile -t -n "$((GSG_GITLEAKS_LOG_LINES + 1))" lines <"$log" || return 1
    if [ "${#lines[@]}" -gt "$GSG_GITLEAKS_LOG_LINES" ]; then
        printf 'gitleaks: its log exceeds %s lines; failing closed\n' "$GSG_GITLEAKS_LOG_LINES"
    fi
    for line in "${lines[@]:0:$GSG_GITLEAKS_LOG_LINES}"; do
        if [[ $line == *$'\e'* ]]; then line="$(strip_ansi "$line")"; fi
        if [[ $line =~ ^[^[:space:]]+[[:space:]]+(ERR|FTL)[[:space:]]+(.*)$ ]]; then
            msg="${BASH_REMATCH[2]}"
        elif [[ $line =~ ^[^[:space:]]+[[:space:]]+WRN[[:space:]]+(skipping[[:space:]].*)$ ]]; then
            msg="${BASH_REMATCH[1]}"
        else
            continue
        fi
        msg="$(msg_words "$msg")"
        msg="${msg:0:300}"
        printf 'gitleaks: %s\n' "${msg//[^[:print:]]/?}"
        shown=$((shown + 1))
        if [ "$shown" -ge "$GSG_GITLEAKS_SHOWN_MAX" ]; then break; fi
    done
    return 0
}
