#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"

# ^ why a copy of run.sh over tiny test files, not the real suite; the runner's file selection is what is under test, and a real run takes hours
# ^ invariant rt_make builds $SANDBOX/rt/tests with the real run.sh, a fetch stub returning 0 and one tiny test file per path given
# ^ why SC2016 is off here; the $(...) in the printf format is expanded by the generated test file, not by this function
# shellcheck disable=SC2016
rt_make() {
    local root="$SANDBOX/rt" path
    rm -rf -- "$root"
    mkdir -p -- "$root/tests" || return 1
    cp -- "$GSG_PROJECT/tests/run.sh" "$root/tests/run.sh" || return 1
    printf '#!/usr/bin/env bash\nexit 0\n' >"$root/tests/fetch-test-tools.sh" || return 1
    chmod 755 "$root/tests/run.sh" "$root/tests/fetch-test-tools.sh" || return 1
    for path in "$@"; do
        mkdir -p -- "$root/tests/${path%/*}" || return 1
        printf '#!/usr/bin/env bash\nprintf "PASS    %%s::test_one\\n" "$(basename -- "${BASH_SOURCE[0]}" .sh)"\n' >"$root/tests/$path" || return 1
    done
}

# ^ invariant rt_run ARG... runs the copied runner from the fake project root, the way a developer or run.cmd does
rt_run() {
    cd -- "$SANDBOX/rt" || return 1
    run_cap env -i "${GSG_ENV[@]}" bash tests/run.sh "$@"
    cd -- "$SANDBOX" || return 1
}

# ^ invariant rt_ran prints the base names of the PASS lines in $OUT, in the order they ran, on one line
rt_ran() {
    local line out=""
    while IFS= read -r line; do
        case "$line" in "PASS    "*) line="${line#PASS    }"; out="$out${out:+ }${line%%::*}" ;; esac
    done <<<"$OUT"
    printf '%s' "$out"
}

RT_TREE=(core/test_b.sh scan/test_a.sh scan/test_c.sh integrations/smartgit/test_d.sh integrations/desktop/test_e.sh deep/x/y/test_z.sh empty/README.md)

test_no_argument_runs_every_test_file_one_and_two_levels_down_ordered_by_base_name() {
    rt_make "${RT_TREE[@]}" || return 1
    rt_run
    assert_rc 0 "no argument"
    assert_eq "$(rt_ran)" "test_a test_b test_c test_d test_e" "base-name order across folders and depths"
    assert_contains "$OUT" "SUMMARY: 5 passed, 0 failed, 0 skipped (total 5)" "five files, the one three levels down is not listed"
}

test_a_folder_argument_runs_exactly_the_files_of_that_folder() {
    rt_make "${RT_TREE[@]}" || return 1
    rt_run tests/scan
    assert_rc 0 "folder argument"
    assert_eq "$(rt_ran)" "test_a test_c" "only tests/scan"
    rt_run tests/scan/
    assert_eq "$(rt_ran)" "test_a test_c" "a trailing slash is the same folder"
}

test_a_nested_folder_argument_runs_the_files_one_level_below_ordered_by_base_name() {
    rt_make "${RT_TREE[@]}" || return 1
    rt_run tests/integrations
    assert_rc 0 "nested folder"
    assert_eq "$(rt_ran)" "test_d test_e" "smartgit and desktop, by base name not by folder"
    rt_run tests/integrations/smartgit
    assert_eq "$(rt_ran)" "test_d" "the leaf folder alone"
}

test_the_tests_folder_argument_runs_the_same_list_as_no_argument() {
    local arg
    rt_make "${RT_TREE[@]}" || return 1
    for arg in tests tests/ ./tests "tests\\"; do
        rt_run "$arg"
        assert_rc 0 "argument $arg"
        assert_eq "$(rt_ran)" "test_a test_b test_c test_d test_e" "argument $arg: the files two folders down are included"
    done
}

test_a_file_argument_runs_that_file_only() {
    rt_make "${RT_TREE[@]}" || return 1
    rt_run tests/scan/test_c.sh
    assert_rc 0 "file argument"
    assert_eq "$(rt_ran)" "test_c" "one file"
    rt_run tests/core/test_b.sh tests/scan/test_a.sh
    assert_eq "$(rt_ran)" "test_b test_a" "several arguments keep the order given"
}

test_a_backslash_path_as_run_cmd_passes_it_runs_the_file_and_the_folder() {
    rt_make "${RT_TREE[@]}" || return 1
    rt_run 'tests\scan\test_a.sh'
    assert_rc 0 "backslash file"
    assert_eq "$(rt_ran)" "test_a" "the file named with backslashes"
    rt_run 'tests\integrations'
    assert_rc 0 "backslash folder"
    assert_eq "$(rt_ran)" "test_d test_e" "the folder named with a backslash"
}

test_a_bad_argument_fails_by_name_and_runs_nothing() {
    rt_make "${RT_TREE[@]}" || return 1
    rt_run tests/scan tests/nope
    assert_rc 1 "bad argument"
    assert_contains "$OUT" "FAIL" "reports a failure"
    assert_contains "$OUT" "tests/nope" "names the argument"
    assert_empty "$(rt_ran)" "the good argument before it did not run either"
    assert_not_contains "$OUT" "SUMMARY" "no test ran"
}

test_a_folder_without_a_test_file_fails_naming_the_folder() {
    rt_make "${RT_TREE[@]}" || return 1
    rt_run tests/empty
    assert_rc 1 "empty folder"
    assert_contains "$OUT" "FAIL    no test files found in tests/empty" "names the folder"
    assert_empty "$(rt_ran)" "nothing ran"
}

RUNNER="$GSG_PROJECT/tests/run.sh"
RUNNER_BOUND_SECONDS=60
# ^ external the parallel mode needs ps -o and kill; Git Bash has no ps -o and run.sh would fetch the Windows tools
RUNNER_PARALLEL_WINDOWS_REASON="the runner's parallel mode is checked on Linux and macOS here; Windows has its own run"

# ^ why a fixture is a file run with bash, not a function; the runner starts each test file as its own process
# ^ invariant takes NAME BODY pairs, writes $SANDBOX/fx/NAME for each, reports a setup failure itself; rc 1 = none written
runner_fixtures() {
    mkdir -p "$SANDBOX/fx" "$SANDBOX/tmp" || { fail "fixture setup failed: mkdir"; return 1; }
    while [ "$#" -ge 2 ]; do
        printf '%s\n' "$2" >"$SANDBOX/fx/$1" || { fail "fixture setup failed: $1"; return 1; }
        shift 2
    done
}

# ^ invariant runs run.sh with the job count on the files, bounded; a runner waiting forever fails here with exit 124
runner_run() {
    local jobs="$1"
    shift
    run_cap timeout "$RUNNER_BOUND_SECONDS" env GSG_TEST_JOBS="$jobs" TMPDIR="$SANDBOX/tmp" bash "$RUNNER" "$@"
}

test_parallel_mode_prints_what_serial_mode_prints_for_normal_files() {
    local serial
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "$RUNNER_PARALLEL_WINDOWS_REASON"; fi
    runner_fixtures test_a.sh "printf 'PASS    a::one\nSKIPPED a::two (why)\n'" \
        test_b.sh "printf 'PASS    b::one\nFAIL    b::two (test status 1)\n'; exit 1" || return 1
    runner_run 1 "$SANDBOX/fx/test_a.sh" "$SANDBOX/fx/test_b.sh"
    serial="$OUT"
    assert_rc 1 "serial run with a failing file"
    runner_run 2 "$SANDBOX/fx/test_a.sh" "$SANDBOX/fx/test_b.sh"
    assert_rc 1 "parallel run with a failing file"
    assert_eq "$OUT" "$serial" "the parallel output is the serial output"
    assert_contains "$OUT" "SUMMARY: 2 passed, 1 failed, 1 skipped (total 4)" "counts"
}

# ^ why the fixture kills its own worker, not a fault injected into run.sh; the real subshell dies as in a crash and writes no exit status
# ^ invariant the process chain is worker subshell, timeout, this file; the grandparent is the worker, never run.sh itself
# shellcheck disable=SC2016
test_parallel_mode_reports_a_file_whose_worker_died_instead_of_waiting_forever() {
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "$RUNNER_PARALLEL_WINDOWS_REASON"; fi
    runner_fixtures test_dies.sh 'printf "PASS    dies::one\n"; kill -9 "$(ps -o ppid= -p "$PPID" | tr -d " ")"' \
        test_fine.sh "printf 'PASS    fine::one\n'" || return 1
    runner_run 2 "$SANDBOX/fx/test_dies.sh" "$SANDBOX/fx/test_fine.sh"
    assert_rc 1 "a dead worker fails the run (124 means the runner waited forever)"
    assert_contains "$OUT" "FAIL    test_dies.sh produced no exit status (its worker died)" "the dead worker is named"
    assert_contains "$OUT" "PASS    fine::one" "the other file is still shown"
    assert_contains "$OUT" "SUMMARY: 1 passed, 1 failed, 0 skipped (total 2)" "the dead file is one failure"
}

COST_FILES=(a b c d e f g h i)
COST_WAIT_TENTHS=300

# ^ why the fixtures log to a file, not to the clock; the holder keeps one job until every file has started, and the log is the start order
# ^ invariant cost_fixture NAME HOLD LOG COUNT prints a test file; HOLD 1 logs and waits for COUNT lines, HOLD 0 waits for a line and logs; bounded
# ^ hazard a serial run must not wait, with GSG_TEST_JOBS 1 the file prints its PASS line and ends
# shellcheck disable=SC2016
cost_fixture() {
    printf '%s\n' '#!/usr/bin/env bash' \
        "name=$1 hold=$2 log='$3' count=$4 limit=$COST_WAIT_TENTHS" \
        'if [ "${GSG_TEST_JOBS:-1}" -le 1 ]; then printf "PASS    %s::ran\n" "$name"; exit 0; fi' \
        'lines=0' \
        'wait_for() { local i=0 l=(); while [ "$i" -lt "$limit" ]; do l=(); [ -f "$log" ] && mapfile -t l <"$log"; lines=${#l[@]}; [ "$lines" -ge "$1" ] && return 0; sleep 0.1; i=$((i + 1)); done; return 1; }' \
        'ok=0' \
        'if [ "$hold" = 1 ]; then printf "%s\n" "$name" >>"$log"; wait_for "$count" || ok=1; else wait_for 1 || ok=1; [ "$ok" = 0 ] && printf "%s\n" "$name" >>"$log"; fi' \
        '[ "$ok" = 0 ] || { printf "FAIL    %s::gave up waiting (%s lines)\n" "$name" "$lines"; exit 1; }' \
        'printf "PASS    %s::ran\n" "$name"'
}

# ^ invariant cost_make builds $SANDBOX/rc/tests with run.sh, a fetch stub, a cost list and test_a..test_i; test_e is unlisted, test_g is malformed, h and i tie
cost_make() {
    local root="$SANDBOX/rc" n hold
    rm -rf -- "$root"
    mkdir -p -- "$root/tests/ctx" "$SANDBOX/tmp" || return 1
    cp -- "$GSG_PROJECT/tests/run.sh" "$root/tests/run.sh" || return 1
    printf '#!/usr/bin/env bash\nexit 0\n' >"$root/tests/fetch-test-tools.sh" || return 1
    chmod 755 "$root/tests/run.sh" "$root/tests/fetch-test-tools.sh" || return 1
    printf '%s\n' '# test costs: name, Windows seconds, Linux seconds' '' 'test_a - 10' 'test_b 500 5' 'test_c 100 300' 'test_d 100 1' \
        'test_f - 0' 'test_g oops' 'test_h 7 50' 'test_i 7 50' >"$root/tests/test-costs.list" || return 1
    for n in "${COST_FILES[@]}"; do
        hold=0
        if [ "$n" = e ]; then hold=1; fi
        cost_fixture "test_$n" "$hold" "$root/start.log" "${#COST_FILES[@]}" >"$root/tests/ctx/test_$n.sh" || return 1
    done
}

# ^ invariant unlisted and malformed files start first in argument order; Windows follows its column and the Linux column breaks ties, elsewhere Linux
test_parallel_mode_starts_the_costliest_files_first_and_prints_in_argument_order() {
    local want="test_e test_g test_c test_h test_i test_a test_b test_d test_f" serial n
    local -a args=()
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then want="test_e test_g test_b test_c test_d test_h test_i test_a test_f"; fi
    cost_make || return 1
    for n in "${COST_FILES[@]}"; do args+=("$SANDBOX/rc/tests/ctx/test_$n.sh"); done
    run_cap timeout "$RUNNER_BOUND_SECONDS" env GSG_TEST_JOBS=1 TMPDIR="$SANDBOX/tmp" bash "$SANDBOX/rc/tests/run.sh" "${args[@]}"
    serial="$OUT"
    assert_rc 0 "serial run"
    run_cap timeout "$RUNNER_BOUND_SECONDS" env GSG_TEST_JOBS=2 TMPDIR="$SANDBOX/tmp" bash "$SANDBOX/rc/tests/run.sh" "${args[@]}"
    assert_rc 0 "parallel run (124 means a wait never ended)"
    assert_eq "$(tr '\n' ' ' <"$SANDBOX/rc/start.log")" "$want " "the start order"
    assert_eq "$(rt_ran)" "test_a test_b test_c test_d test_e test_f test_g test_h test_i" "the print order is the argument order"
    assert_eq "$OUT" "$serial" "the parallel output is the serial output"
    assert_contains "$OUT" "SUMMARY: 9 passed, 0 failed, 0 skipped (total 9)" "counts"
}

run_file_tests
