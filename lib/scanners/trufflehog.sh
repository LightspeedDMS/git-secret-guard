# shellcheck shell=bash

scan_trufflehog() {
    local scan_dir="$1" out="$2"
    local rows="$out/trufflehog.rows" errs="$out/trufflehog.errors"
    local results="$out/trufflehog.json" log="$out/trufflehog.log"
    local rc problem nrows completed parse_failed=0
    : >"$rows" && : >"$errs" || return 1

    if problem="$(tool_unusable trufflehog "${TRUFFLEHOG_BIN:-}")" || problem="$(tool_unusable timeout "${TIMEOUT_BIN:-}")"; then
        printf 'trufflehog: %s; nothing was scanned\n' "$problem" >"$errs" || return 1
        return 0
    fi

    # ^ why timeout --foreground, not plain timeout; plain timeout makes its own process group => the hook's group kill misses it
    # ^ see test:test_term_signal_stops_the_scanners_and_removes_the_private_temp_dir
    "$TIMEOUT_BIN" --foreground -k 5 "$SCAN_TIMEOUT_SECONDS" "$TRUFFLEHOG_BIN" filesystem "$scan_dir" \
        --results=verified,unknown --fail --fail-on-scan-errors --no-update --json --no-color \
        >"$results" 2>"$log"
    rc=$?

    # ^ security jq stderr dropped everywhere below => its parse errors would quote the candidate value
    if [ -s "$results" ]; then
        # shellcheck disable=SC2016
        if ! "$JQ_BIN" -r --arg prefix "$scan_dir/" "$GSG_JQ_CLEAN"'
            (if type == "object" then . else error("not an object") end)
            | (.SourceMetadata.Data.Filesystem // {}) as $fs
            | ($fs.line // 0) as $line
            | ["trufflehog", (.DetectorName // "?" | clean),
               (if .Verified == true then "verified" else "unknown" end),
               ($fs.file // "?" | ltrimstr($prefix) | clean),
               (if ($line | type) == "number" and $line >= 1 then ($line | floor | tostring) else "?" end)]
            | @tsv' "$results" >"$rows" 2>/dev/null; then
            : >"$rows"
            parse_failed=1
            printf 'trufflehog: could not parse its results; failing closed\n' >>"$errs" || return 1
        fi
    fi
    nrows="$(wc -l <"$rows")" || return 1

    if [ "$rc" -eq 124 ]; then
        printf 'trufflehog: timed out after %ss; the scan did not complete\n' "$SCAN_TIMEOUT_SECONDS" >>"$errs" || return 1
    elif [ "$rc" -eq 183 ]; then
        if [ "$nrows" -eq 0 ] && [ "$parse_failed" -eq 0 ]; then
            printf 'trufflehog: reported findings (exit 183) but returned no readable results\n' >>"$errs" || return 1
        fi
    elif [ "$rc" -ne 0 ]; then
        printf 'trufflehog: scan failed (exit %s)\n' "$rc" >>"$errs" || return 1
    fi

    # ^ hazard a tool exiting 0 without scanning (wrong binary, /bin/true) => completion needs the "finished scanning" line with chunks >= 1
    # ^ external 3.99.2 logs chunks = 1 for blank-only content, 0 only for an empty tree
    # ^ see test:test_a_completion_line_with_zero_chunks_is_an_error_for_a_non_empty_tree
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 183 ]; then
        # shellcheck disable=SC2016
        completed="$("$JQ_BIN" -Rs '[split("\n")[] | fromjson?
            | select(type == "object" and .msg == "finished scanning" and (.chunks | type) == "number" and .chunks >= 1)] | length' "$log" 2>/dev/null)"
        case "$completed" in
            [1-9]*) ;;
            *) printf 'trufflehog: did not report a completed scan (no "finished scanning" log line with chunks >= 1); failing closed\n' >>"$errs" || return 1 ;;
        esac
    fi

    # ^ hazard 3.99.2 --fail-on-scan-errors still exits 0 on an unreadable file => error-level log lines are scan errors too
    # ^ security only the log "msg" is printed; structured fields can carry verifier URLs holding the candidate value
    # shellcheck disable=SC2016
    if ! "$JQ_BIN" -rRs "$GSG_JQ_CLEAN"'
        [split("\n")[] | fromjson?
         | select(type == "object" and ((.level // "") | tostring | test("^(error|dpanic|panic|fatal)$")))
         | "trufflehog: " + ((.msg // "error-level log line without a message") | clean | .[0:300])]
        | unique | .[0:5][]' "$log" >>"$errs" 2>/dev/null; then
        printf 'trufflehog: could not read its log; failing closed\n' >>"$errs" || return 1
    fi
    return 0
}
