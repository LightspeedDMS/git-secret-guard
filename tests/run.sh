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
case "$(uname -s)" in
    MINGW64_NT-*)
        FILE_TIMEOUT_SECONDS="${GSG_TEST_FILE_TIMEOUT:-2400}"
        JOBS="${GSG_TEST_JOBS:-$(nproc)}"
        tools_cache="${XDG_CACHE_HOME:-$HOME/.cache}/git-secret-guard-test-tools"
        if ! "$TESTS_DIR/fetch-test-tools.sh" --check "$tools_cache" >/dev/null; then
            "$TESTS_DIR/fetch-test-tools.sh" || printf 'WARNING the test tools could not be fetched\n'
        fi
        ;;
esac

files=()
if [ "$#" -gt 0 ]; then
    # ^ external tests\run.cmd passes what cmd typed; bash reads a backslash path, basename does not
    files=("${@//\\//}")
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

# ^ why parallel only on request off Windows, not everywhere; each file has its own sandbox, the Linux and macOS output stays as it always was
# ^ external starting a process costs far more on Windows; the suite takes hours one file at a time
start_files() {
    local i running=0
    for i in "${!files[@]}"; do
        while [ "$running" -ge "$JOBS" ]; do
            wait -n
            running=$((running - 1))
        done
        (
            timeout "$FILE_TIMEOUT_SECONDS" bash "${files[$i]}" >"$out_dir/$i.log" 2>&1
            echo "$?" >"$out_dir/$i.rc.tmp"
            mv -- "$out_dir/$i.rc.tmp" "$out_dir/$i.rc"
        ) &
        running=$((running + 1))
    done
    wait
}

if [ "$JOBS" -gt 1 ]; then
    out_dir="$(mktemp -d)" || exit 2
    trap 'rm -rf -- "$out_dir"' EXIT
    start_files &
fi

for i in "${!files[@]}"; do
    f="${files[$i]}"
    results="$(mktemp)" || exit 2
    if [ "$JOBS" -gt 1 ]; then
        while [ ! -f "$out_dir/$i.rc" ]; do sleep 1; done
        cp -- "$out_dir/$i.log" "$results" || exit 2
        cat -- "$results"
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
