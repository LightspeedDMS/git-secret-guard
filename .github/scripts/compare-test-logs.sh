#!/usr/bin/env bash
# Compares two logs of tests/run.sh: the branch under test and, optionally, its base.
# Usage: compare-test-logs.sh <head.log> [base.log]
# Exit status: 0 = no regression, 1 = a test fails on the head that does not fail on the base (or fails at all when there is no base),
#              2 = the head log has no SUMMARY line, so the suite did not run to the end.
set -u
head_log="${1:?usage: compare-test-logs.sh head.log [base.log]}"
base_log="${2:-}"
summary="${GITHUB_STEP_SUMMARY:-/dev/null}"

# results of one log: lines that start with $2 (FAIL or SKIPPED), without a trailing timing such as (0.2s), sorted and unique
norm() { grep -E "^$2" "$1" 2>/dev/null | sed -E 's/[[:space:]]*\([0-9.]+ ?m?s\)//' | sort -u; }

head_summary="$(grep -E '^SUMMARY' "$head_log" | tail -1)"
if [ -z "$head_summary" ]; then
    echo "::error::the head log has no SUMMARY line; the suite did not run to the end. Last lines:"
    tail -15 "$head_log"
    exit 2
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
norm "$head_log" FAIL >"$tmp/head.fail"
norm "$head_log" SKIPPED >"$tmp/head.skip"
: >"$tmp/base.fail"
: >"$tmp/base.skip"
base_summary="(no base run)"
if [ -n "$base_log" ] && [ -f "$base_log" ]; then
    base_summary="$(grep -E '^SUMMARY' "$base_log" | tail -1)"
    base_summary="${base_summary:-(the base run produced no SUMMARY line)}"
    norm "$base_log" FAIL >"$tmp/base.fail"
    norm "$base_log" SKIPPED >"$tmp/base.skip"
fi

comm -13 "$tmp/base.fail" "$tmp/head.fail" >"$tmp/new.fail"
comm -23 "$tmp/base.fail" "$tmp/head.fail" >"$tmp/gone.fail"
comm -12 "$tmp/base.fail" "$tmp/head.fail" >"$tmp/same.fail"
diff "$tmp/base.skip" "$tmp/head.skip" >"$tmp/skip.diff" || true

report() {
    echo "### Test suite on Linux"
    echo
    echo "- head: \`$head_summary\`"
    echo "- base: \`$base_summary\`"
    echo
    if [ -s "$tmp/new.fail" ]; then
        if [ -n "$base_log" ]; then echo "**Failing on the head only (regressions):**"; else echo "**Failing:**"; fi
        echo '```'; cat "$tmp/new.fail"; echo '```'
    else
        echo "No test fails on the head that does not also fail on the base."
    fi
    if [ -s "$tmp/same.fail" ]; then
        echo; echo "Failing on both (already failing before this change):"
        echo '```'; cat "$tmp/same.fail"; echo '```'
    fi
    if [ -s "$tmp/gone.fail" ]; then
        echo; echo "Failing on the base only (fixed by this change):"
        echo '```'; cat "$tmp/gone.fail"; echo '```'
    fi
    if [ -s "$tmp/skip.diff" ]; then
        echo; echo "Skipped tests that differ (a test that skips only on the head may hide a problem):"
        echo '```diff'; cat "$tmp/skip.diff"; echo '```'
    fi
}
report | tee -a "$summary"

[ ! -s "$tmp/new.fail" ]
