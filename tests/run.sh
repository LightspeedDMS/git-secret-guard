#!/usr/bin/env bash
set -u
set -o pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
FILE_TIMEOUT_SECONDS="${GSG_TEST_FILE_TIMEOUT:-900}"

files=()
if [ "$#" -gt 0 ]; then
    files=("$@")
else
    for f in "$TESTS_DIR"/test_*.sh; do
        [ -e "$f" ] && files+=("$f")
    done
fi
if [ "${#files[@]}" -eq 0 ]; then
    printf 'FAIL    no test files found in %s\n' "$TESTS_DIR"
    exit 1
fi

passed=0
failed=0
skipped=0
for f in "${files[@]}"; do
    results="$(mktemp)" || exit 2
    timeout "$FILE_TIMEOUT_SECONDS" bash "$f" 2>&1 | tee "$results"
    file_rc="${PIPESTATUS[0]}"
    counted=0
    file_failed=0
    while IFS= read -r line; do
        case "$line" in
            "PASS "*) passed=$((passed + 1)); counted=$((counted + 1)) ;;
            "FAIL "*) failed=$((failed + 1)); file_failed=$((file_failed + 1)); counted=$((counted + 1)) ;;
            "SKIPPED "*) skipped=$((skipped + 1)); counted=$((counted + 1)) ;;
        esac
    done <"$results"
    rm -f -- "$results"
    if [ "$counted" -eq 0 ]; then
        printf 'FAIL    %s produced no test results (exit %s)\n' "$(basename -- "$f")" "$file_rc"
        failed=$((failed + 1))
    elif [ "$file_rc" -ne 0 ] && [ "$file_failed" -eq 0 ]; then
        printf 'FAIL    %s exited %s without reporting a failure\n' "$(basename -- "$f")" "$file_rc"
        failed=$((failed + 1))
    fi
done

printf '\nSUMMARY: %s passed, %s failed, %s skipped (total %s)\n' \
    "$passed" "$failed" "$skipped" "$((passed + failed + skipped))"
[ "$failed" -eq 0 ]
