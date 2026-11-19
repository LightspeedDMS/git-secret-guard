#!/usr/bin/env bash
# ^ invariant usage [ROOT] (default the current directory); prints tests/project/test_quality.sh first, after it each other Markdown-reading test file, sorted
# ^ invariant exit 0 with one line or more; exit 1 with a message and no output on extra args, a bad ROOT, no tests/project/test_quality.sh, or a failed scan
set -u
set -o pipefail

quality="tests/project/test_quality.sh"
root="${1:-.}"
if [ "$#" -gt 1 ]; then
    printf 'usage: docs-tests.sh [ROOT]\n' >&2
    exit 1
fi
cd -- "$root" || {
    printf 'docs-tests: cannot enter %s\n' "$root" >&2
    exit 1
}
if [ ! -f "$quality" ]; then
    printf 'docs-tests: %s is missing under %s\n' "$quality" "$root" >&2
    exit 1
fi

# ^ invariant the two globs are the depths tests/run.sh runs with no argument; a new depth there needs the same here
# ^ why nullglob, not the literal pattern; a depth with no file would reach grep as a missing file (rc 2), and the quality file keeps the array non-empty
shopt -s nullglob
test_files=(tests/*/test_*.sh tests/*/*/test_*.sh)
shopt -u nullglob

# ^ why a non-comment line with the root variable (plain, braced, quoted) before /...md, not any mention of .md; it is how a test reads Markdown
# ^ invariant tests/project/test_ci_plan.sh scans every test file for a reader this pattern misses
# shellcheck disable=SC2016
others="$(LC_ALL=C grep -l -E '^[^#]*\$\{?GSG_PROJECT\}?"?/[^ ]*\.md' "${test_files[@]}")" || [ "$?" -eq 1 ] || {
    printf 'docs-tests: the scan of the test files failed\n' >&2
    exit 1
}
others="$(printf '%s\n' "$others" | LC_ALL=C grep -v -x -e "$quality" -e '')" || [ "$?" -eq 1 ] || {
    printf 'docs-tests: filtering the list failed\n' >&2
    exit 1
}

printf '%s\n' "$quality"
if [ -n "$others" ]; then printf '%s\n' "$others" | LC_ALL=C sort -u; fi
