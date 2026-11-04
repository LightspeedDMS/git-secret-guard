# shellcheck shell=bash

GSG_BETTERLEAKS_RENAMED_SUFFIX=.gsg-committed
GSG_BETTERLEAKS_IGNORE_NAMES=(.gitleaksignore .betterleaksignore)
GSG_BETTERLEAKS_LOG_LINES=5000
GSG_BETTERLEAKS_SHOWN_MAX=5
GSG_BETTERLEAKS_MSG_MAX=300
GSG_BETTERLEAKS_KILL_AFTER_SECONDS=5
GSG_BETTERLEAKS_TIMEOUT_RC=124
GSG_BETTERLEAKS_KEY_RULE=aws-access-key-id
GSG_BETTERLEAKS_IGNORE_MAX_LINES=20000
GSG_BETTERLEAKS_IGNORE_TOO_LONG_RC=2
# ^ external lib/betterleaks-rule.toml sits beside lib/scanners => the path comes from this file, never from settings or the environment
GSG_BETTERLEAKS_RULE_FILE="${BASH_SOURCE[0]%/*}/../betterleaks-rule.toml"

# ^ why our own rule, not the built-ins alone; 1.9.0 reports an AWS key ID only with its secret within 5 lines (gitleaks 8.30.1 flagged a lone ID)
# ^ invariant no HEAD config = one run with built-in rules plus our rule; a HEAD config = its own run exactly as written plus a rule-only run
scan_betterleaks() {
    local scan_dir="$1" out="$2"
    local rows="$out/betterleaks.rows" errs="$out/betterleaks.errors"
    local conf="$out/betterleaks.toml" ignore_dir="$out/betterleaks-ignore"
    local problem tree rc extra=0 run_conf="$out/betterleaks.toml"
    # ^ invariant out and scan dirs absolute => the cd in betterleaks_scan_once cannot invalidate the config/report/ignore paths
    case "$out" in /*) ;; *) return 1 ;; esac
    case "$scan_dir" in /*) ;; *) return 1 ;; esac
    [ -d "$scan_dir" ] || return 1
    : >"$rows" && : >"$errs" || return 1

    if problem="$(tool_unusable betterleaks "${BETTERLEAKS_BIN:-}")" || problem="$(tool_unusable timeout "${TIMEOUT_BIN:-}")"; then
        printf 'betterleaks: %s; nothing was scanned\n' "$problem" >"$errs" || return 1
        return 0
    fi
    if [ ! -r "$GSG_BETTERLEAKS_RULE_FILE" ]; then
        printf 'betterleaks: the shipped rule file %s is unreadable; nothing was scanned\n' "$GSG_BETTERLEAKS_RULE_FILE" >"$errs" || return 1
        return 0
    fi

    # ^ security explicit --config and --gitleaks-ignore-path => a commit cannot mute itself with its own .gitleaks.toml, .betterleaks.toml or ignore file
    # ^ security only copies the hook took from HEAD are honored; the staged or working-tree versions never reach --config / --gitleaks-ignore-path
    mkdir -p -- "$ignore_dir" || return 1
    { printf '[extend]\nuseDefault = true\n\n' && cat -- "$GSG_BETTERLEAKS_RULE_FILE"; } >"$conf" || return 1
    run_conf="$conf"
    if [ -f "$out/$GSG_REPO_GITLEAKS_TOML" ]; then
        run_conf="$out/$GSG_REPO_GITLEAKS_TOML"
        extra=1
    fi
    if [ -f "$out/$GSG_REPO_GITLEAKS_IGNORE" ]; then
        betterleaks_write_ignore "$out/$GSG_REPO_GITLEAKS_IGNORE" "$ignore_dir/.gitleaksignore" "$errs"
        rc=$?
        if [ "$rc" -eq "$GSG_BETTERLEAKS_IGNORE_TOO_LONG_RC" ]; then return 0; fi
        if [ "$rc" -ne 0 ]; then return 1; fi
    fi
    tree="$(betterleaks_stage_tree "$scan_dir" "$out")" || return 1

    betterleaks_scan_once betterleaks "$tree" "$run_conf" "$ignore_dir" "$out/betterleaks" "$scan_dir" "$errs" "$rows" || return 1
    if [ "$extra" -eq 1 ]; then
        betterleaks_scan_once "betterleaks ($GSG_BETTERLEAKS_KEY_RULE rule)" "$tree" "$conf" "$ignore_dir" "$out/betterleaks-extra" \
            "$scan_dir" "$errs" "$out/betterleaks-extra.rows" "$GSG_BETTERLEAKS_KEY_RULE" || return 1
        cat -- "$out/betterleaks-extra.rows" >>"$rows" || return 1
    fi
    betterleaks_drop_pair_key_rows "$rows"
}

# ^ security betterleaks honors root .gitleaksignore and .betterleaksignore whatever --gitleaks-ignore-path says; nested ones are ignored (probed on 1.9.0)
# ^ why rename in a copy, not delete; the added lines of the file stay scanned
# ^ invariant prints the tree to scan, the scan dir itself when no root ignore file exists, else a copy with each one renamed
betterleaks_stage_tree() {
    local scan_dir="$1" out="$2" name tree="$1"
    local -a renamed=()
    for name in "${GSG_BETTERLEAKS_IGNORE_NAMES[@]}"; do
        if [ -e "$scan_dir/$name" ]; then renamed+=("$name"); fi
    done
    if [ "${#renamed[@]}" -gt 0 ]; then
        tree="$out/betterleaks-tree"
        cp -a -- "$scan_dir" "$tree" || return 1
        for name in "${renamed[@]}"; do
            if [ -e "$tree/$name$GSG_BETTERLEAKS_RENAMED_SUFFIX" ]; then return 1; fi
            mv -- "$tree/$name" "$tree/$name$GSG_BETTERLEAKS_RENAMED_SUFFIX" || return 1
        done
    fi
    printf '%s\n' "$tree"
}

# ^ invariant args = label, scan tree, config, ignore dir, file stem (<stem>.json and <stem>.log), scan dir, errors file (appended), rows file (overwritten)
# ^ security --validation is never passed => betterleaks makes no network request (probed on 1.9.0, off by default and one request with the flag)
# ^ why cwd = scan dir with path ".", not an absolute path; fingerprints become "src/a.txt:rule:N", usable in a committed .gitleaksignore
betterleaks_scan_once() {
    local label="$1" tree="$2" conf="$3" ignore_dir="$4" stem="$5" scan_dir="$6" errs="$7" rows="$8" only_rule="${9:-}" rc
    local -a isolate=()
    if [ -n "$only_rule" ]; then isolate=(--enable-rule "$only_rule"); fi
    (
        cd -- "$tree" || exit 1
        exec "$TIMEOUT_BIN" --foreground -k "$GSG_BETTERLEAKS_KILL_AFTER_SECONDS" "$SCAN_TIMEOUT_SECONDS" "$BETTERLEAKS_BIN" dir . \
            --config "$conf" "${isolate[@]}" --gitleaks-ignore-path "$ignore_dir" --redact \
            --report-format json --report-path "$stem.json" --exit-code "$GSG_BETTERLEAKS_LEAK_RC" \
            --no-banner --no-color >/dev/null 2>"$stem.log"
    )
    rc=$?
    betterleaks_collect "$label" "$rc" "$stem.json" "$scan_dir" "$rows" "$errs" || return 1
    betterleaks_log_errors "$label" "$stem.log" >>"$errs"
}

# ^ why add a mapped line, not rename the rule; gitleaks 8.30.1 reported a lone key ID as aws-access-token, old fingerprints must keep muting
# ^ invariant pure data transform, no TOML; the file is bounded and every other line is copied verbatim; rc 0 ok, TOO_LONG_RC = error recorded in ERRS
betterleaks_write_ignore() {
    local src="$1" dst="$2" errs="$3" line cr=$'\r'
    local -a lines=()
    mapfile -t -n "$((GSG_BETTERLEAKS_IGNORE_MAX_LINES + 1))" lines <"$src" || return 1
    if [ "${#lines[@]}" -gt "$GSG_BETTERLEAKS_IGNORE_MAX_LINES" ]; then
        printf 'betterleaks: .gitleaksignore at HEAD has more than %s lines; nothing was scanned\n' "$GSG_BETTERLEAKS_IGNORE_MAX_LINES" >"$errs" || return 1
        return "$GSG_BETTERLEAKS_IGNORE_TOO_LONG_RC"
    fi
    : >"$dst" || return 1
    for line in "${lines[@]}"; do
        printf '%s\n' "$line" >>"$dst" || return 1
        if [[ $line =~ ^(.+):aws-access-token:([0-9]+)(${cr}?)$ ]]; then
            printf '%s:%s:%s%s\n' "${BASH_REMATCH[1]}" "$GSG_BETTERLEAKS_KEY_RULE" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" >>"$dst" || return 1
        fi
    done
}

# ^ invariant args = label, run status, report, scan dir, rows file (overwritten), errors file (appended); rows are scanner, rule, status, file, line
# shellcheck disable=SC2016
betterleaks_collect() {
    local label="$1" rc="$2" report="$3" scan_dir="$4" rows="$5" errs="$6" nrows windows=0
    if gsg_is_windows; then windows=1; fi
    : >"$rows" || return 1
    if [ "$rc" -eq "$GSG_BETTERLEAKS_TIMEOUT_RC" ]; then
        printf '%s: timed out after %ss; the scan did not complete\n' "$label" "$SCAN_TIMEOUT_SECONDS" >>"$errs" || return 1
    elif [ "$rc" -ne 0 ] && [ "$rc" -ne "$GSG_BETTERLEAKS_LEAK_RC" ]; then
        printf '%s: scan failed (exit %s)\n' "$label" "$rc" >>"$errs" || return 1
    elif [ ! -s "$report" ]; then
        printf '%s: no report was written (exit %s); failing closed\n' "$label" "$rc" >>"$errs" || return 1
    # ^ external betterleaks.exe is assumed to write backslashes into File like gitleaks.exe did (unverified) => they become "/" before the prefix is trimmed
    # ^ security jq stderr dropped => parse errors quote the input
    elif ! "$JQ_BIN" -r --arg prefix "$scan_dir/" --arg suffix "$GSG_BETTERLEAKS_RENAMED_SUFFIX" --arg names "${GSG_BETTERLEAKS_IGNORE_NAMES[*]}" --arg windows "$windows" \
        "$GSG_JQ_CLEAN"'
            (if type == "array" then .[] else error("not an array") end)
            | (if type == "object" then . else error("not an object") end)
            | (.StartLine // 0) as $line
            | (.File // "?" | (if $windows == "1" then gsub("\\\\"; "/") else . end) | ltrimstr($prefix)) as $file
            | ($file | rtrimstr($suffix)) as $base
            | ["betterleaks", (.RuleID // "?" | clean), "finding",
               ((if ($file | endswith($suffix)) and (($names | split(" ")) | index($base)) then $base else $file end) | clean),
               (if ($line | type) == "number" and $line >= 1 then ($line | floor | tostring) else "?" end)]
            | @tsv' "$report" >"$rows" 2>/dev/null; then
        : >"$rows" || return 1
        printf '%s: could not parse its report; failing closed\n' "$label" >>"$errs" || return 1
    else
        nrows="$(wc -l <"$rows")" || return 1
        if [ "$rc" -eq "$GSG_BETTERLEAKS_LEAK_RC" ] && [ "$nrows" -eq 0 ]; then
            printf '%s: reported leaks (exit %s) but its report holds none\n' "$label" "$rc" >>"$errs" || return 1
        fi
    fi
    return 0
}

# ^ why drop the key-ID row, not the token row; aws-access-token and our rule both match the ID line of a pair, one finding must not print twice
# ^ invariant only a key-ID row sharing file and line with an aws-access-token row goes; a lone ID on any other line stays
betterleaks_drop_pair_key_rows() {
    local rows="$1" tmp="$1.pairs"
    awk -F'\t' -v key="$GSG_BETTERLEAKS_KEY_RULE" '
        NR == FNR { if ($2 == "aws-access-token") seen[$4 "\t" $5] = 1; next }
        !($2 == key && (($4 "\t" $5) in seen))' "$rows" "$rows" >"$tmp" || return 1
    mv -f -- "$tmp" "$rows"
}

# ^ hazard 1.9.0 exits 0 or 42 after "WRN skipping file" (unreadable input) => skipped files are scan errors
# ^ invariant output of this function is appended to the errors file; any line printed here blocks the commit via report_results
betterleaks_log_errors() {
    local label="$1" log="$2" line msg shown=0
    local -a lines=()
    mapfile -t -n "$((GSG_BETTERLEAKS_LOG_LINES + 1))" lines <"$log" || return 1
    if [ "${#lines[@]}" -gt "$GSG_BETTERLEAKS_LOG_LINES" ]; then
        printf '%s: its log exceeds %s lines; failing closed\n' "$label" "$GSG_BETTERLEAKS_LOG_LINES" || return 1
    fi
    for line in "${lines[@]:0:$GSG_BETTERLEAKS_LOG_LINES}"; do
        if [[ $line == *$'\e'* ]]; then line="$(strip_ansi "$line")"; fi
        if [[ $line =~ ^[^[:space:]]+[[:space:]]+(ERR|FTL)[[:space:]]+(.*)$ ]]; then
            msg="${BASH_REMATCH[2]}"
        elif [[ $line =~ ^[^[:space:]]+[[:space:]]+WRN[[:space:]]+(skipping[[:space:]].*)$ ]]; then
            msg="${BASH_REMATCH[1]}"
        else
            continue
        fi
        msg="$(msg_words "$msg")"
        msg="${msg:0:$GSG_BETTERLEAKS_MSG_MAX}"
        printf '%s: %s\n' "$label" "${msg//[^[:print:]]/?}" || return 1
        shown=$((shown + 1))
        if [ "$shown" -ge "$GSG_BETTERLEAKS_SHOWN_MAX" ]; then break; fi
    done
    return 0
}
