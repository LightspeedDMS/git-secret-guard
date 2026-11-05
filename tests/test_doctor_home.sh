#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

# ^ security every repository lives under the sandbox home or $SANDBOX/roots => a default run never reads the real home
TAB=$'\t'
FIND_LEVELS_FOUND=31
FIND_LEVELS_LOST=32

home_repo() {
    local dir="$LC_HOME/$1"
    mkdir -p -- "$dir" && gitx init -q "$dir" || return 1
    gitx -C "$dir" commit -q --allow-empty --no-verify -m init
}
home_disable() { gitx -C "$LC_HOME/$1" config hook.git-secret-guard.enabled false; }
dr_disable() { gitx -C "$DR_ROOTS/$1" config hook.git-secret-guard.enabled false; }
home_real() { realpath -- "$LC_HOME"; }

# ^ invariant prints N path components, each named d
deep_rel() {
    local i out="d"
    for ((i = 1; i < $1; i++)); do out+="/d"; done
    printf '%s' "$out"
}

# ^ invariant writes a valid record holding one repo line for the absolute path $1
record_repo() {
    mkdir -p -- "$LC_STATE" || return 1
    printf 'git-secret-guard findings 1\ntime 2026-01-01T00:00:00Z\nrepo%s%s%s-%sdisabled in local config: hook.git-secret-guard.enabled=false\n' \
        "$TAB" "$1" "$TAB" "$TAB" >"$LC_STATE/findings"
}

# ^ external macOS find words a protected folder "Operation not permitted"; the stand-in runs the real find and rewrites its Permission denied lines
# ^ why a pipeline with exit status from PIPESTATUS, not a process substitution; the rewritten lines must be in the log before find returns
find_eperm_standin() {
    local real
    real="$(dr_which find)" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/bash\nexec 3>&1\n%q "$@" 2>&1 1>&3 | sed %q >&2\nexit "${PIPESTATUS[0]}"\n' "$real" 's/: Permission denied$/: Operation not permitted/' >"$SANDBOX/pathbin/find" || return 1
    chmod 755 "$SANDBOX/pathbin/find"
}

test_the_default_root_is_the_home_directory_not_dev() {
    local hr
    dr_begin && home_repo work/off && home_disable work/off && home_repo work/fine || return 1
    hr="$(home_real)"
    gsg doctor
    assert_rc 1 "a repository outside ~/Dev with the hook disabled"
    assert_contains "$OUT" "  $hr/work/off
    PROBLEM  disabled in local config" "listed from a run with no --roots"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "both repositories under home counted"
}

test_a_repository_seven_levels_below_home_is_checked() {
    local hr
    dr_begin && home_repo a/b/c/d/e/f/seven && home_disable a/b/c/d/e/f/seven || return 1
    hr="$(home_real)"
    gsg doctor
    assert_rc 1 "a repository seven levels down"
    assert_contains "$OUT" "  $hr/a/b/c/d/e/f/seven
    PROBLEM  disabled in local config" "found and judged"
}

test_the_search_reaches_31_levels_and_stops_there_and_a_record_beyond_is_kept() {
    local found lost
    found="$(deep_rel "$((FIND_LEVELS_FOUND - 1))")/found"
    lost="$(deep_rel "$((FIND_LEVELS_LOST - 1))")/lost"
    dr_begin && dr_repo "$found" && dr_disable "$found" && dr_repo "$lost" && dr_disable "$lost" || return 1
    record_repo "$DR_REAL/$lost" || return 1
    doctor
    assert_rc 1 "the repository at 31 levels is disabled"
    assert_contains "$OUT" "$DR_REAL/$found" "31 levels below the root is searched"
    assert_not_contains "$OUT" "/lost" "32 levels is not"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "only the reachable one is counted"
    assert_contains "$(<"$LC_STATE/findings")" "repo${TAB}$DR_REAL/$lost${TAB}-${TAB}disabled in local config" "the record of the repository beyond the bound is kept, it exists so it is not gone"
}

test_node_modules_is_skipped_at_any_depth() {
    dr_begin && dr_repo ok && dr_repo a/b/c/d/e/f/node_modules/pkg && dr_disable a/b/c/d/e/f/node_modules/pkg || return 1
    doctor
    assert_rc 0 "the repository below node_modules is not reached"
    assert_contains "$OUT" "summary: 1 repos, 1 covered" "only the other repository"
    assert_not_contains "$OUT" "node_modules" "never named"
}

test_roots_narrow_the_run_to_the_directory_given() {
    local hr
    dr_begin && home_repo outside && home_disable outside && dr_repo inside && dr_disable inside || return 1
    hr="$(home_real)"
    doctor
    assert_rc 1 "the repository under the root is disabled"
    assert_contains "$OUT" "  $DR_REAL/inside" "the root's repository is listed"
    assert_not_contains "$OUT" "$hr/outside" "a repository under home but outside the root is not"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "one repository checked"
}

test_a_default_run_on_linux_searches_the_library_directory() {
    local hr
    dr_begin && home_repo Library/proj && home_disable Library/proj || return 1
    hr="$(home_real)"
    gsg doctor
    assert_rc 1 "nothing is left out away from macOS"
    assert_contains "$OUT" "  $hr/Library/proj" "listed"
}

test_a_default_run_on_macos_leaves_out_the_library_and_roots_can_name_it() {
    local hr
    dr_begin_macos && home_repo Library/Caches/proj && home_disable Library/Caches/proj || return 1
    home_repo work/proj && home_disable work/proj && home_repo Dev/Library/unity && home_disable Dev/Library/unity || return 1
    hr="$(home_real)"
    gsg doctor
    assert_rc 1 "disabled repositories outside the library"
    assert_contains "$OUT" "  $hr/work/proj" "the rest of home is searched"
    assert_contains "$OUT" "  $hr/Dev/Library/unity" "a Library folder that is not ~/Library is searched"
    assert_not_contains "$OUT" "$hr/Library/Caches/proj" "the library folder is not"
    assert_contains "$OUT" "summary: 2 repos, 0 covered" "two repositories checked"
    gsg doctor --roots "$LC_HOME/Library"
    assert_rc 1 "naming ~/Library searches it"
    assert_contains "$OUT" "  $hr/Library/Caches/proj" "the repository inside is listed"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "and only it"
}

# ^ why a locked folder in each place, not one; the second find, naming unreadable folders, must leave ~/Library out as well
test_the_library_is_left_out_of_the_unreadable_folder_search_too() {
    local hr
    dr_begin_macos && mkdir -p -- "$LC_HOME/locked" "$LC_HOME/Library/locked2" || return 1
    chmod 000 "$LC_HOME/locked" "$LC_HOME/Library/locked2" || return 1
    hr="$(home_real)"
    gsg doctor
    assert_rc 1 "an unreadable folder is a PROBLEM"
    assert_contains "$OUT" "PROBLEM  cannot read $hr/locked; repositories below it are not checked" "the folder outside the library is named"
    assert_not_contains "$OUT" "locked2" "the one inside ~/Library is not"
}

test_a_recorded_repository_under_the_library_is_kept_by_a_default_macos_run() {
    local hr
    dr_begin_macos && home_repo Library/proj && home_disable Library/proj || return 1
    hr="$(home_real)"
    record_repo "$hr/Library/proj" || return 1
    gsg doctor
    assert_not_contains "$OUT" "$hr/Library/proj" "not searched, so not listed"
    assert_contains "$(<"$LC_STATE/findings")" "repo${TAB}$hr/Library/proj${TAB}-${TAB}disabled in local config" "not searched is not proven gone, the record stays"
}

test_a_default_run_on_macos_leaves_out_the_trash_and_roots_can_name_it() {
    local hr
    dr_begin_macos && home_repo .Trash/proj && home_disable .Trash/proj && home_repo work/proj && home_disable work/proj || return 1
    hr="$(home_real)"
    gsg doctor
    assert_rc 1 "a disabled repository outside the trash"
    assert_contains "$OUT" "  $hr/work/proj" "the rest of home is searched"
    assert_not_contains "$OUT" "$hr/.Trash/proj" "the trash folder is not"
    assert_contains "$OUT" "summary: 1 repos, 0 covered" "one repository checked"
    gsg doctor --roots "$LC_HOME/.Trash"
    assert_rc 1 "naming the trash folder searches it"
    assert_contains "$OUT" "  $hr/.Trash/proj" "the repository inside is listed"
}

test_an_unreadable_trash_is_no_problem_on_a_default_macos_run() {
    dr_begin_macos && mkdir -p -- "$LC_HOME/.Trash" && chmod 000 "$LC_HOME/.Trash" || return 1
    gsg doctor
    assert_rc 0 "a blocked trash folder is not a finding"
    assert_not_contains "$OUT" "cannot read" "nothing is listed as unreadable"
}

test_an_unreadable_trash_beside_another_locked_folder_is_not_named() {
    local hr
    dr_begin_macos && mkdir -p -- "$LC_HOME/.Trash" "$LC_HOME/locked" && chmod 000 "$LC_HOME/.Trash" "$LC_HOME/locked" || return 1
    hr="$(home_real)"
    gsg doctor
    assert_rc 1 "the other unreadable folder is still a PROBLEM"
    assert_contains "$OUT" "PROBLEM  cannot read $hr/locked; repositories below it are not checked" "named"
    assert_not_contains "$OUT" ".Trash" "the second find leaves the trash folder out too"
}

test_a_default_run_on_linux_searches_the_trash_directory() {
    local hr
    dr_begin && home_repo .Trash/proj && home_disable .Trash/proj || return 1
    hr="$(home_real)"
    gsg doctor
    assert_rc 1 "nothing is left out away from macOS"
    assert_contains "$OUT" "  $hr/.Trash/proj" "listed"
}

test_a_recorded_repository_under_the_trash_is_kept_by_a_default_macos_run() {
    local hr
    dr_begin_macos && home_repo .Trash/proj && home_disable .Trash/proj || return 1
    hr="$(home_real)"
    record_repo "$hr/.Trash/proj" || return 1
    gsg doctor
    assert_not_contains "$OUT" "$hr/.Trash/proj" "not searched, so not listed"
    assert_contains "$(<"$LC_STATE/findings")" "repo${TAB}$hr/.Trash/proj${TAB}-${TAB}disabled in local config" "not searched is not proven gone, the record stays"
}

test_a_folder_find_calls_operation_not_permitted_is_listed_and_the_rest_is_checked() {
    dr_begin && dr_repo fine && dr_repo off && dr_disable off || return 1
    mkdir -p -- "$DR_ROOTS/locked" && chmod 000 "$DR_ROOTS/locked" && find_eperm_standin || return 1
    doctor
    assert_rc 1 "a folder macOS blocks is a PROBLEM"
    assert_not_contains "$ERR" "could not read everything" "and not a doctor error"
    assert_contains "$OUT" "PROBLEM  cannot read $DR_REAL/locked; repositories below it are not checked" "named"
    assert_contains "$OUT" "summary: 2 repos, 1 covered" "the other repositories were judged"
}

test_any_other_find_failure_is_still_a_doctor_error() {
    dr_begin && dr_repo fine || return 1
    printf '#!/bin/sh\necho "find: x: Input/output error" >&2\nexit 1\n' >"$SANDBOX/pathbin/find" && chmod 755 "$SANDBOX/pathbin/find" || return 1
    doctor
    assert_rc 2 "an I/O error is not a permission problem"
    assert_contains "$ERR" "could not read everything under $DR_REAL" "says what failed"
}

test_operation_not_permitted_is_explained_only_when_every_line_says_so() {
    dr_begin && mkdir -p -- "$DR_ROOTS/locked" && chmod 000 "$DR_ROOTS/locked" || return 1
    # shellcheck disable=SC2016
    run_cap env -i "${LC_ENV[@]}" bash -c '
        source "$1/lib/common.sh" && source "$1/lib/doctor_repos.sh" && source "$1/lib/doctor.sh"
        DR_WORK="$(mktemp -d)"; DR_UNREADABLE=(); declare -A DR_BAD_SEEN=()
        printf "find: x: Operation not permitted\n" >"$DR_WORK/find.err"
        doctor_unreadable "$2"; a=$?
        printf "find: x: Operation not permitted\nfind: y: No such file or directory\n" >"$DR_WORK/find.err"
        doctor_unreadable "$2"; b=$?
        rm -rf -- "$DR_WORK"; printf "%s %s" "$a" "$b"' _ "$GSG_PROJECT" "$DR_ROOTS"
    assert_eq "$OUT" "0 1" "an all-permission log names the locked folder, a mixed one is left unexplained"
}

test_a_home_that_names_no_directory_needs_roots() {
    dr_begin || return 1
    set_env HOME="$SANDBOX/no-home"
    gsg doctor
    assert_rc 2 "HOME is not a directory"
    assert_contains "$ERR" "default root $SANDBOX/no-home is not a directory; pass --roots DIR" "says how to fix it"
    assert_empty "$OUT" "and prints no report"
}

run_file_tests
