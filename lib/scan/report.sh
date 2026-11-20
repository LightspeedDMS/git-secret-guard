# shellcheck shell=bash

GSG_SCANNERS=(trufflehog betterleaks)

# ^ security only rows (scanner, detector, status, file, line) and error messages are ever printed => adapters never write a value into these files
collect() {
    local s
    case "$2" in rows | errors) ;; *) return 1 ;; esac
    [ -d "$1" ] || return 1
    for s in "${GSG_SCANNERS[@]}"; do
        if [ -f "$1/$s.$2" ]; then
            cat -- "$1/$s.$2" || return 1
        elif [ "$2" = errors ]; then
            printf '%s: the scanner wrapper produced no result; failing closed\n' "$s"
        fi
    done
}

# ^ invariant prints "<n> <word>" with an s when n is not 1
_report_count() {
    if [ "$1" -eq 1 ]; then
        printf '%s %s' "$1" "$2"
    else
        printf '%s %ss' "$1" "$2"
    fi
}

# ^ security the version comes from the settings file and reaches the terminal => only digits and dots are shown, anything else drops the version
_report_tool_label() {
    if [[ ${2:-} =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        printf '%s %s' "$1" "$2"
    else
        printf '%s' "$1"
    fi
}

# ^ invariant args = files, added lines, exempted files, elapsed whole seconds; all four are numbers the hook counted, no scanner text is used
# ^ invariant one line on stderr; the exempted count appears only when above 0
report_pass_line() {
    local exempt=""
    if [ "$3" -gt 0 ]; then exempt=", $(_report_count "$3" file) exempted"; fi
    ui_prefix 2 ok
    printf '%s%s: scanned %s, %s (%s, %s): no findings%s, %ss\n' "$REPLY" "$GSG_NAME" "$(_report_count "$1" file)" "$(_report_count "$2" "added line")" \
        "$(_report_tool_label trufflehog "${TRUFFLEHOG_VERSION:-}")" "$(_report_tool_label betterleaks "${BETTERLEAKS_VERSION:-}")" "$exempt" "$4" >&2
}

# ^ invariant arg = exempted files; the scan tree held no file, no scanner ran
report_nothing_line() {
    ui_prefix 2 ok
    if [ "$1" -gt 0 ]; then
        printf '%s%s: no added lines to scan (%s exempted)\n' "$REPLY" "$GSG_NAME" "$(_report_count "$1" file)" >&2
    else
        printf '%s%s: no added lines to scan\n' "$REPLY" "$GSG_NAME" >&2
    fi
}

# ^ invariant rc 1 = nothing to re-check (no file, an empty file, or exactly the magic line and a time line); rc 0 = anything else
# ^ why a damaged file counts as due, not as clean; the re-check validates the record and says so, the hook does not parse it
report_reminder_due() {
    local l1="" l2="" l3="" rc=0
    if [ ! -s "$1" ]; then return 1; fi
    { { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3 || rc=1; } <"$1"; } 2>/dev/null || return 0
    if [ "$l1" = "$GSG_FINDINGS_MAGIC" ] && [[ $l2 == "time "* ]] && [ "$rc" -eq 1 ] && [ -z "$l3" ]; then return 1; fi
    return 0
}

# ^ invariant $1 = a file with doctor --recheck's stdout, $2 = the findings record; prints the reminder on stderr, rc 1 and no output = unreadable
# ^ security only PROBLEM texts doctor already sanitised are copied, control characters mapped to "?" again here; no stderr of doctor is used
# ^ coupled inspect/doctor_findings.sh:doctor_rec_print_machine and doctor_rec_print_kept print the shapes named in the awk BEGIN block (path, PROBLEM lines)
report_reminder() {
    local l1 l2 date lines n
    { { IFS= read -r l1 && IFS= read -r l2; } <"$2"; } 2>/dev/null || return 1
    if [[ ! $l2 =~ ^time\ ([0-9]{4}-[0-9]{2}-[0-9]{2})T ]]; then return 1; fi
    date="${BASH_REMATCH[1]}"
    lines="$(awk '
        function clean(s) { gsub(/[[:cntrl:]]/, "?", s); return s }
        BEGIN { path_indent = "  "; machine_prefix = "  PROBLEM  "; repo_prefix = "    PROBLEM  " }
        /^machine:$/ { sec = "m"; next }
        /^repos with findings:$/ { sec = "r"; next }
        sec == "r" && /^  [^ ]/ { path = clean(substr($0, length(path_indent) + 1)); next }
        sec == "m" && index($0, machine_prefix) == 1 { print "  machine: " clean(substr($0, length(machine_prefix) + 1)); next }
        sec == "r" && index($0, repo_prefix) == 1 { print "  " path ": " clean(substr($0, length(repo_prefix) + 1)) }
    ' "$1")" || return 1
    if [ -z "$lines" ]; then return 1; fi
    n="$(printf '%s\n' "$lines" | wc -l)" || return 1
    n="${n//[[:space:]]/}"
    ui_prefix 2 WARNING
    printf '%s%s: %s still open (doctor run %s):\n%s\n  run %s doctor for the full report\n' "$REPLY" "$GSG_NAME" "$(_report_count "$n" "coverage problem")" "$date" "$lines" "$GSG_NAME" >&2
}

# ^ invariant $1 = a short reason made of text the hook wrote itself, never of doctor's output
report_reminder_failed() {
    printf '%s: coverage re-check failed (%s); run %s doctor\n' "$GSG_NAME" "$1" "$GSG_NAME" >&2
}

GSG_REPORT_MAX_FINGERPRINTS=10

# ^ invariant $1 = the sorted rows file, $2 = "" or message; prints fixed words and the scanner, rule, file and line fields of the rows, never a value
# ^ invariant at most GSG_REPORT_MAX_FINGERPRINTS fingerprint lines and one "... and N more" line; no icon, no escape sequence; --no-verify is printed after
# ^ why skip, not guess, the fingerprint when the line is "?", the path has "?" or "\", or it is a root ignore file; the row may not match betterleaks
_report_guidance() {
    awk -F'\t' -v mode="${2:-}" -v max_fp="$GSG_REPORT_MAX_FINGERPRINTS" '
        $1 == "trufflehog" { tf = 1 }
        $1 == "betterleaks" {
            bl = 1
            if ($5 == "?" || index($4, "?") || index($4, "\\") || $4 == ".gitleaksignore" || $4 == ".betterleaksignore") next
            if (listed < max_fp) { listed++; fp[listed] = $4 ":" $2 ":" $5 } else { more++ }
        }
        END {
            print "What to do:"
            if (mode == "message") {
                print "  1. Write the message again without the value, and rotate a real credential."
                print "  2. A false positive that must stay in the message: put the marker of every scanner that reports the line on that same line"
                print "     (trufflehog: trufflehog:ignore, betterleaks: betterleaks:allow). The marker stays in the commit message."
            } else {
                print "  1. A real credential: remove it from the change and rotate it. Nothing below is for a real credential."
                print "  2. A false positive or a test value, one line: put the marker of every scanner that reports the line on that same line."
                if (tf && bl) print "       trufflehog: trufflehog:ignore    betterleaks: betterleaks:allow    both: trufflehog:ignore betterleaks:allow"
                else if (tf) print "       trufflehog: trufflehog:ignore"
                else print "       betterleaks: betterleaks:allow"
                print "     A marker works in this commit."
                step = 3
                if (listed > 0) {
                    print "  3. A betterleaks finding on a line that cannot hold a marker: add its line to .gitleaksignore at the repository root:"
                    for (i = 1; i <= listed; i++) print "       " fp[i]
                    if (more > 0) print "       ... and " more " more (<path>:<rule>:<line> of each betterleaks row above)"
                    step = 4
                }
                print "  " step ". A whole path of test data: add \"<glob>  # <reason>\" to .secret-scan-ignore at the repository root."
                if (tf) print "     trufflehog has no per-finding file: its finding on a line that cannot hold a marker needs this step."
                if (listed > 0) print "  .gitleaksignore and .secret-scan-ignore are read from the last commit, never from the commit being made:"
                else print "  .secret-scan-ignore is read from the last commit, never from the commit being made:"
                print "  commit the entry by itself first (git add <file> && git commit -m \"<message>\" <file>), then commit this change."
            }
            print "An automated agent asks its user before adding an exemption or using --no-verify."
        }' "$1" >&2
}

# ^ invariant args = work dir, sorted rows, collected errors; one PROBLEM line per scanner whose own record did not reach them; rc 1 when any
# ^ security bash builtins only (no cat, sort, wc, grep, awk) => a PATH tool losing the rows cannot hide the loss too (#31)
# ^ why the scanner's exit-status marker and its own errors file, not the merged files; the merged files are what a lying tool empties
_report_cross_check() {
    local work="$1" rows="$2" errs="$3" s line need=" " seen=" " lost=0
    for s in "${GSG_SCANNERS[@]}"; do
        if [ -e "$work/$s.found" ]; then need+="$s "; fi
    done
    if [ "$need" != " " ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            for s in "${GSG_SCANNERS[@]}"; do
                if [[ $line == "$s"$'\t'* ]]; then seen+="$s "; fi
            done
        done <"$rows" || return 1
    fi
    for s in "${GSG_SCANNERS[@]}"; do
        if [[ $need == *" $s "* ]] && [[ $seen != *" $s "* ]]; then
            ui_prefix 2 PROBLEM
            printf '%s%s: %s reported findings but none reached the report; nothing was decided\n' "$REPLY" "$GSG_NAME" "$s" >&2
            lost=1
        fi
        if [ -s "$work/$s.errors" ] && [ ! -s "$errs" ]; then
            ui_prefix 2 PROBLEM
            printf '%s%s: %s recorded errors but none reached the report; nothing was decided\n' "$REPLY" "$GSG_NAME" "$s" >&2
            lost=1
        fi
    done
    [ "$lost" -eq 0 ]
}

report_results() {
    local work="${1:-}" rows errs n heading="in lines this commit adds" shown=""
    case "${2:-}" in
        "") ;;
        message)
            heading="in the commit message"
            shown="commit message"
            ;;
        *)
            printf '%s: internal error: unknown report mode [%s]; failing closed\n' "$GSG_NAME" "${2//[^[:print:]]/?}" >&2
            return 1
            ;;
    esac
    if [ -z "$work" ] || [ ! -d "$work" ]; then
        printf '%s: internal error: no work dir to report from; failing closed\n' "$GSG_NAME" >&2
        return 1
    fi
    rows="$work/all.rows"
    errs="$work/all.errors"
    collect "$work" rows >"$work/all.rows.unsorted" || return 1
    LC_ALL=C sort -u -- "$work/all.rows.unsorted" >"$rows" || return 1
    collect "$work" errors >"$errs" || return 1
    local lost=0
    _report_cross_check "$work" "$rows" "$errs" || lost=1

    if [ -s "$errs" ]; then
        ui_prefix 2 PROBLEM
        printf '%s%s: a scanner did not complete, so the commit is blocked:\n' "$REPLY" "$GSG_NAME" >&2
        sed 's/^/  /' "$errs" >&2
    fi
    if [ -s "$rows" ]; then
        n="$(wc -l <"$rows")" || return 1
        # ^ external BSD wc pads the count with spaces and GNU wc does not; the printed line is the same on both
        n="${n//[[:space:]]/}"
        ui_prefix 2 PROBLEM
        printf '%s%s: %s potential secret(s) %s:\n' "$REPLY" "$GSG_NAME" "$n" "$heading" >&2
        awk -F'\t' -v shown="$shown" '{ printf "  %-11s %s (%s)  %s:%s\n", $1, $2, $3, (shown != "" ? shown : $4), $5 }' "$rows" >&2
        printf '  (values are not shown; remove them and rotate any real credential)\n' >&2
        _report_guidance "$rows" "${2:-}" || return 1
    fi
    if [ -s "$errs" ] || [ -s "$rows" ] || [ "$lost" -eq 1 ]; then
        return 1
    fi
    return 0
}
