#!/usr/bin/env bash
# ^ invariant usage check-macos-tests.sh LIST LOG; exit 0 = all listed PASS, 1 = one skipped, failed or absent, 2 = usage, unreadable file or empty list
# ^ invariant the expectations come from names in the list, never a count; a renamed test is "not in the log" and fails
# ^ external CI runs it under Homebrew bash; by hand on a Mac /bin/bash is 3.2 => no mapfile, no associative arrays
set -u
set -o pipefail

list="${1:-}"
log="${2:-}"
if [ "$#" -ne 2 ]; then
    printf 'usage: check-macos-tests.sh LIST LOG\n' >&2
    exit 2
fi
if [ ! -r "$list" ]; then
    printf 'check-macos-tests: cannot read the list %s\n' "$list" >&2
    exit 2
fi
if [ ! -r "$log" ]; then
    printf 'check-macos-tests: cannot read the log %s\n' "$log" >&2
    exit 2
fi

total=0
bad=0
while IFS= read -r id || [ -n "$id" ]; do
    case "$id" in '' | '#'*) continue ;; esac
    total=$((total + 1))
    # ^ why anchored at column 1 with the name as field 2, not a substring match; a longer name or a detail line must not stand in for it
    verdicts="$(awk -v id="$id" '/^(PASS|FAIL|SKIPPED) / && $2 == id { printf "%s ", $1 }' "$log")" || {
        printf 'check-macos-tests: awk failed on %s\n' "$log" >&2
        exit 2
    }
    case "$verdicts" in
        '') printf 'MISSING %s (not in the log)\n' "$id"; bad=$((bad + 1)) ;;
        'PASS ') ;;
        *) printf 'NOT PASS %s (%s)\n' "$id" "${verdicts% }"; bad=$((bad + 1)) ;;
    esac
done <"$list"

if [ "$total" -eq 0 ]; then
    printf 'check-macos-tests: %s lists no tests, which proves nothing\n' "$list" >&2
    exit 2
fi
printf 'check-macos-tests: %s of %s macOS-only tests passed\n' "$((total - bad))" "$total"
[ "$bad" -eq 0 ]
