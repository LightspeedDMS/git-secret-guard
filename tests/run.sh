#!/usr/bin/env bash
set -u
set -o pipefail

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 2
FILE_TIMEOUT_SECONDS="${GSG_TEST_FILE_TIMEOUT:-900}"
JOBS="${GSG_TEST_JOBS:-1}"

# ^ external macOS ships bash 3.2 and BSD tools; Homebrew's bash and the GNU coreutils directory must come first for timeout and env --default-signal
if [ "$(uname -s)" = Darwin ]; then
    brew_prefix="$(brew --prefix 2>/dev/null)" || brew_prefix=""
    if [ -z "$brew_prefix" ]; then
        printf 'FAIL    the tests need Homebrew on macOS (brew --prefix printed nothing)\n'
        exit 2
    fi
    PATH="$brew_prefix/bin:$brew_prefix/opt/coreutils/libexec/gnubin:$PATH"
    export PATH
fi

# ^ external on Windows the pinned jq and scanners live in a test cache, fetched and SHA-256 checked once; a failed fetch leaves the real-scanner tests to skip
COST_COLUMN=linux
case "$(uname -s)" in
    MINGW64_NT-*)
        COST_COLUMN=windows
        FILE_TIMEOUT_SECONDS="${GSG_TEST_FILE_TIMEOUT:-2400}"
        JOBS="${GSG_TEST_JOBS:-$(nproc)}"
        tools_cache="${XDG_CACHE_HOME:-$HOME/.cache}/git-secret-guard-test-tools"
        if ! "$TESTS_DIR/fetch-test-tools.sh" --check "$tools_cache" >/dev/null; then
            "$TESTS_DIR/fetch-test-tools.sh" || printf 'WARNING the test tools could not be fetched\n'
        fi
        ;;
esac

# ^ invariant list_tests DIR prints "base name, tab, path" of each test_*.sh directly in DIR and one level below
list_tests() {
    local f
    for f in "$1"/test_*.sh "$1"/*/test_*.sh; do
        if [ -e "$f" ]; then printf '%s\t%s\n' "${f##*/}" "$f"; fi
    done
}

# ^ why C order, not the shell's glob order; the order must not depend on the locale, and base names are unique
# ^ invariant add_tests DIR... appends the test files of the folders to files, ordered by base name; rc 1 when it found none
add_tests() {
    local before="${#files[@]}" path d
    while IFS=$'\t' read -r _ path; do
        files+=("$path")
    done < <(for d in "$@"; do list_tests "$d"; done | LC_ALL=C sort)
    [ "${#files[@]}" -gt "$before" ]
}

# ^ invariant add_all_tests appends the files of every folder of tests/ (one and two levels below tests/), the list of a run without argument
add_all_tests() {
    local d
    local -a folders=()
    for d in "$TESTS_DIR"/*/; do
        if [ -d "$d" ]; then folders+=("${d%/}"); fi
    done
    add_tests "${folders[@]}"
}

files=()
if [ "$#" -gt 0 ]; then
    # ^ external tests\run.cmd passes what cmd typed; bash reads a backslash path, basename does not
    for arg in "${@//\\//}"; do
        if [ -d "$arg" ]; then
            # ^ why tests/ itself takes the list of no argument, not a one-level list; the integrations files sit one level deeper than a context folder's
            if [ "$(CDPATH='' cd -- "$arg" && pwd -P)" = "$TESTS_DIR" ]; then
                add_all_tests || { printf 'FAIL    no test files found in %s\n' "$arg"; exit 1; }
            else
                add_tests "${arg%/}" || { printf 'FAIL    no test files found in %s\n' "$arg"; exit 1; }
            fi
        elif [ -f "$arg" ]; then
            files+=("$arg")
        else
            printf 'FAIL    %s is neither a test file nor a folder\n' "$arg"
            exit 1
        fi
    done
else
    add_all_tests || { printf 'FAIL    no test files found in %s\n' "$TESTS_DIR"; exit 1; }
fi

passed=0
failed=0
skipped=0

# ^ why start in cost order, not name order; a long file started late stretches the end of the run (the printer below still goes by index)
# ^ invariant order_by_cost sets start_order to the file indices, unlisted files first, after them the costliest in COST_COLUMN, ties by index
# ^ why a malformed list line counts as missing, not as an error; the file starts early and test_cost_list checks the list
order_by_cost() {
    local list="$TESTS_DIR/test-costs.list" i
    start_order=()
    while read -r _ _ _ i; do
        start_order+=("$i")
    done < <(
        { if [ -f "$list" ]; then cat -- "$list" || exit 1; fi; printf '%s\n' '@files'; printf '%s\n' "${files[@]}"; } |
            LC_ALL=C awk -v col="$COST_COLUMN" '
                $0 == "@files" && !seen { seen = 1; idx = 0; next }
                !seen {
                    if (NF == 3 && $1 !~ /^#/ && $3 ~ /^[0-9]+$/ && ($2 ~ /^[0-9]+$/ || $2 == "-")) {
                        win[$1] = ($2 == "-") ? 0 : $2
                        lin[$1] = $3
                    }
                    next
                }
                {
                    n = $0; sub(/^.*\//, "", n); sub(/\.sh$/, "", n)
                    if (n in lin) printf "1 %d %d %d\n", (col == "windows") ? win[n] : 0, lin[n], idx
                    else printf "0 0 0 %d\n", idx
                    idx++
                }' |
            LC_ALL=C sort -k1,1n -k2,2nr -k3,3nr -k4,4n
    )
    [ "${#start_order[@]}" -eq "${#files[@]}" ] || { printf 'FAIL    could not order the test files by cost\n'; exit 2; }
}

# ^ why parallel only on request off Windows, not everywhere; each file has its own sandbox, the Linux and macOS output stays as it always was
# ^ external starting a process costs far more on Windows; the suite takes hours one file at a time
start_files() {
    local i running=0
    for i in "${start_order[@]}"; do
        while [ "$running" -ge "$JOBS" ]; do
            wait -n
            running=$((running - 1))
        done
        (
            worker_rc=0 t_start=0 t_end=0
            printf -v t_start '%(%s)T' -1
            timeout "$FILE_TIMEOUT_SECONDS" bash "${files[$i]}" >"$out_dir/$i.log" 2>&1
            worker_rc="$?"
            printf -v t_end '%(%s)T' -1
            # ^ order the time file is written before the status file, and the printer reads it only after the status file exists; no rename is needed
            # ^ why only builtins here, not date, expr or mv; a process start costs most of a second on Windows and this runs once per file
            # ^ why a failed time write is ignored, not fatal; the time is a report, the status file decides the verdict
            { echo "$((t_end - t_start))" >"$out_dir/$i.time"; } 2>/dev/null
            echo "$worker_rc" >"$out_dir/$i.rc.tmp"
            mv -- "$out_dir/$i.rc.tmp" "$out_dir/$i.rc"
        ) &
        running=$((running + 1))
    done
    wait
}

# ^ invariant waits until file $1 has its status file; rc 1 = the starter ended without one (its worker died); the wait is bounded by the starter
# ^ order the status file is checked again after the starter is seen gone, not before; a worker writes it before the starter returns from its wait
wait_for_status() {
    while [ ! -f "$out_dir/$1.rc" ]; do
        if ! kill -0 "$starter" 2>/dev/null; then
            [ -f "$out_dir/$1.rc" ] && return 0
            return 1
        fi
        sleep 1
    done
}

# ^ invariant print_time_line INDEX PATH prints "TIME    <name without .sh> <seconds>s" from its time file; nothing when it is missing or not whole seconds
# ^ why a bad time file prints nothing, not a failure; the time is a report, and the verdict of the file comes from its status file and its results
# ^ external a CI log has no per-file run time, only the print time of each file; tests/test-costs.list takes its Windows column from these lines
print_time_line() {
    local secs name
    [ -f "$out_dir/$1.time" ] || return 0
    secs="$(<"$out_dir/$1.time")" || return 0
    case "$secs" in '' | *[!0-9]*) return 0 ;; esac
    name="${2##*/}"
    printf 'TIME    %s %ss\n' "${name%.sh}" "$secs"
}

if [ "$JOBS" -gt 1 ]; then
    out_dir="$(mktemp -d)" || exit 2
    trap 'rm -rf -- "$out_dir"' EXIT
    order_by_cost
    start_files &
    starter=$!
fi

for i in "${!files[@]}"; do
    f="${files[$i]}"
    results="$(mktemp)" || exit 2
    if [ "$JOBS" -gt 1 ]; then
        if ! wait_for_status "$i"; then
            printf 'FAIL    %s produced no exit status (its worker died)\n' "$(basename -- "$f")"
            failed=$((failed + 1))
            rm -f -- "$results"
            continue
        fi
        cp -- "$out_dir/$i.log" "$results" || exit 2
        cat -- "$results"
        print_time_line "$i" "$f"
        file_rc="$(<"$out_dir/$i.rc")"
    else
        timeout "$FILE_TIMEOUT_SECONDS" bash "$f" 2>&1 | tee "$results"
        file_rc="${PIPESTATUS[0]}"
    fi
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
