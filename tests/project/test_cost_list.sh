#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

TC_LIST_NAME=tests/test-costs.list
TC_MIN_TEST_FILES=80

# ^ invariant tc_test_names prints the base name, without .sh, of every test_*.sh under tests/ at any depth, C-sorted
tc_test_names() { find "$GSG_PROJECT/tests" -name 'test_*.sh' | sed 's|.*/||; s|\.sh$||' | LC_ALL=C sort; }

TC_LINE_RE='^([A-Za-z0-9_]+) (-|[0-9]+) [0-9]+$'

# ^ invariant tc_cost_list_findings LIST NAME... prints a line per problem of LIST against the test base names (bad format, repeat, stale, absent)
# shellcheck disable=SC2016
# ^ why a malformed line leaves its name without an entry, not unreported; run.sh treats it as unlisted too
# ^ invariant the messages name tests/test-costs.list whatever LIST is; rc 1 only when LIST cannot be read
tc_cost_list_findings() {
    local list="$1" line name n=0
    local -A want=() seen=()
    shift
    for name in "$@"; do want[$name]=1; done
    [ -r "$list" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$line" in '' | '#'*) continue ;; esac
        if ! [[ $line =~ $TC_LINE_RE ]]; then
            printf '%s:%d: malformed line [%s], expected <test name> <Windows seconds or -> <Linux seconds>, whole numbers\n' "$TC_LIST_NAME" "$n" "$line"
            continue
        fi
        name="${BASH_REMATCH[1]}"
        if [ -n "${seen[$name]:-}" ]; then
            printf '%s:%d: %s is listed twice, keep one line\n' "$TC_LIST_NAME" "$n" "$name"
        elif [ -z "${want[$name]:-}" ]; then
            printf '%s:%d: %s names no test file, delete the line\n' "$TC_LIST_NAME" "$n" "$name"
        fi
        seen[$name]=1
    done <"$list"
    for name in "$@"; do
        if [ -z "${seen[$name]:-}" ]; then
            printf '%s has no line for %s, add `%s <Windows seconds or -> <Linux seconds>` with its measured seconds\n' "$TC_LIST_NAME" "$name" "$name"
        fi
    done
}

test_the_cost_list_names_every_test_file_once_and_no_other() {
    local out line
    local -a names
    mapfile -t names < <(tc_test_names)
    [ "${#names[@]}" -ge "$TC_MIN_TEST_FILES" ] || { fail "only ${#names[@]} test files found"; return 1; }
    out="$(tc_cost_list_findings "$GSG_PROJECT/$TC_LIST_NAME" "${names[@]}")" || { fail "the cost list check could not run"; return 1; }
    while IFS= read -r line; do
        if [ -n "$line" ]; then fail "$line"; fi
    done <<<"$out"
}

# ^ why the messages name tests/test-costs.list, not the path the check read; a reader edits the real list, the planted one lives in a sandbox
test_the_cost_list_check_flags_a_missing_a_stale_a_duplicate_and_malformed_lines() {
    local out="" list="$SANDBOX/costs-planted.list"
    printf '%s\n' '# a comment' '' 'test_a - 5' 'test_b 100 7' 'test_b 200 8' 'test_stale - 3' 'test_bad one two' 'test_neg - -1' 'test_c 5' >"$list" || return 1
    out="$(tc_cost_list_findings "$list" test_a test_b test_c test_d)" || fail "the cost list check could not run"
    assert_contains "$out" "$TC_LIST_NAME:5: test_b is listed twice, keep one line" "a duplicate"
    assert_contains "$out" "$TC_LIST_NAME:6: test_stale names no test file, delete the line" "a stale entry"
    assert_contains "$out" "$TC_LIST_NAME:7: malformed line [test_bad one two]" "words instead of seconds"
    assert_contains "$out" "$TC_LIST_NAME:8: malformed line [test_neg - -1]" "a negative number"
    assert_contains "$out" "$TC_LIST_NAME:9: malformed line [test_c 5]" "two fields"
    assert_contains "$out" "$TC_LIST_NAME has no line for test_c, add" "a malformed line leaves its file without an entry"
    assert_contains "$out" "$TC_LIST_NAME has no line for test_d, add \`test_d <Windows seconds or -> <Linux seconds>\` with its measured seconds" "a missing entry says what to add"
    assert_not_contains "$out" "test_a" "a good entry is not reported"
    assert_eq "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 7 "seven findings and nothing else"
    if tc_cost_list_findings "$SANDBOX/no-such.list" test_a >/dev/null 2>&1; then fail "a list that cannot be read must fail the check"; fi
}

run_file_tests
