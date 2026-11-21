# shellcheck shell=bash
# ^ invariant these helpers run report_results alone on a work dir of empty scanner files, with no scanner behind it

WORK=""

begin() {
    new_repo "$1" || return 1
    WORK="$SANDBOX/work-$1"
    mkdir -p -- "$WORK" || return 1
    : >"$WORK/trufflehog.rows" && : >"$WORK/betterleaks.rows" && : >"$WORK/trufflehog.errors" && : >"$WORK/betterleaks.errors" || return 1
}

# ^ invariant report_with STAND_IN [MODE] runs report_results on the work dir; STAND_IN is shell text run first, it can use $W (the work dir)
report_with() {
    # shellcheck disable=SC2016
    run_cap env -i "${GSG_ENV[@]}" bash -c 'source "$1/lib/core/common.sh" && source "$1/lib/scan/report.sh" || exit 9
        W="$2"
        eval "$3"
        report_results "$2" "$4"' _ "$SHARE" "$WORK" "$1" "${2:-}"
}
