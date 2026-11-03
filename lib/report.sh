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
    printf '%s: scanned %s, %s (%s, %s): no findings%s, %ss\n' "$GSG_NAME" "$(_report_count "$1" file)" "$(_report_count "$2" "added line")" \
        "$(_report_tool_label trufflehog "${TRUFFLEHOG_VERSION:-}")" "$(_report_tool_label betterleaks "${BETTERLEAKS_VERSION:-}")" "$exempt" "$4" >&2
}

# ^ invariant arg = exempted files; the scan tree held no file, no scanner ran
report_nothing_line() {
    if [ "$1" -gt 0 ]; then
        printf '%s: no added lines to scan (%s exempted)\n' "$GSG_NAME" "$(_report_count "$1" file)" >&2
    else
        printf '%s: no added lines to scan\n' "$GSG_NAME" >&2
    fi
}

report_results() {
    local work="${1:-}" rows errs n
    if [ -z "$work" ] || [ ! -d "$work" ]; then
        printf '%s: internal error: no work dir to report from; failing closed\n' "$GSG_NAME" >&2
        return 1
    fi
    rows="$work/all.rows"
    errs="$work/all.errors"
    collect "$work" rows >"$work/all.rows.unsorted" || return 1
    LC_ALL=C sort -u -- "$work/all.rows.unsorted" >"$rows" || return 1
    collect "$work" errors >"$errs" || return 1

    if [ -s "$errs" ]; then
        printf '%s: a scanner did not complete, so the commit is blocked:\n' "$GSG_NAME" >&2
        sed 's/^/  /' "$errs" >&2
    fi
    if [ -s "$rows" ]; then
        n="$(wc -l <"$rows")" || return 1
        # ^ external BSD wc pads the count with spaces and GNU wc does not; the printed line is the same on both
        n="${n//[[:space:]]/}"
        printf '%s: %s potential secret(s) in lines this commit adds:\n' "$GSG_NAME" "$n" >&2
        awk -F'\t' '{ printf "  %-11s %s (%s)  %s:%s\n", $1, $2, $3, $4, $5 }' "$rows" >&2
        printf '  (values are not shown; remove them and rotate any real credential)\n' >&2
    fi
    if [ -s "$errs" ] || [ -s "$rows" ]; then
        return 1
    fi
    return 0
}
