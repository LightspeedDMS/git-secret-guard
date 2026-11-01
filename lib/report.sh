# shellcheck shell=bash

GSG_SCANNERS=(trufflehog gitleaks)

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
        printf '%s: %s potential secret(s) in lines this commit adds:\n' "$GSG_NAME" "$n" >&2
        awk -F'\t' '{ printf "  %-10s %s (%s)  %s:%s\n", $1, $2, $3, $4, $5 }' "$rows" >&2
        printf '  (values are not shown; remove them and rotate any real credential)\n' >&2
    fi
    if [ -s "$errs" ] || [ -s "$rows" ]; then
        return 1
    fi
    return 0
}
