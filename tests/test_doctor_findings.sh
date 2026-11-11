#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/doctor.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/doctor.sh"

REC_MAGIC="git-secret-guard findings 1"
REC_TIME_RE='^time [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
REC_HEADER_LINES=2
TAB=$'\t'
MANY_REPOS=55
HOLDER_SECONDS=60
# ^ external each lock attempt starts a few processes => on Windows the 300 attempts outlast 60 seconds and a dead holder is rightly broken
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then HOLDER_SECONDS=900; fi
DEAD_PID=99999999
OLD_GIT_VERSION=2.40.0
CONCURRENT_PAIRS=4
SHOWN_LINE_MAX=100

recheck() { gsg doctor --recheck; }
rec_file() { printf '%s' "$LC_STATE/findings"; }
dr_disable() { gitx -C "$DR_ROOTS/$1" config hook.git-secret-guard.enabled false; }
dr_enable() { gitx -C "$DR_ROOTS/$1" config --unset hook.git-secret-guard.enabled; }
off_text() { printf 'disabled in local config: hook.git-secret-guard.enabled=false (%s/%s/.git/config); remove that key to cover this repository' "$DR_REAL" "$1"; }

# ^ invariant the record body = every line after the header lines
rec_body() { tail -n "+$((REC_HEADER_LINES + 1))" "$(rec_file)"; }

# ^ invariant writes a valid record whose body is the arguments, one line each
write_record() {
    mkdir -p -- "$LC_STATE" || return 1
    { printf '%s\ntime 2026-01-01T00:00:00Z\n' "$REC_MAGIC"; if [ "$#" -gt 0 ]; then printf '%s\n' "$@"; fi; } >"$(rec_file)"
}

# ^ invariant a valid record has header and time lines, only machine and repo lines of the exact shape after them, and leaves no temp file or lock behind
assert_valid_record() {
    local line n=0 leftovers
    local -a lines=()
    mapfile -t lines <"$(rec_file)" || {
        fail "$1: record missing or unreadable"
        return 1
    }
    assert_eq "${lines[0]:-}" "$REC_MAGIC" "$1: header"
    [[ ${lines[1]:-} =~ $REC_TIME_RE ]] || fail "$1: time line [${lines[1]:-}]"
    for line in "${lines[@]:$REC_HEADER_LINES}"; do
        n=$((n + 1))
        [[ $line =~ ^(machine"$TAB"[^"$TAB"]+|repo"$TAB"/[^"$TAB"]+"$TAB"(-|/[^"$TAB"]+)"$TAB"[^"$TAB"]+)$ ]] || fail "$1: record line $n is not valid [${line:0:$SHOWN_LINE_MAX}]"
    done
    leftovers="$(find "$LC_STATE" -mindepth 1 -name 'findings.*' | LC_ALL=C sort)"
    assert_empty "$leftovers" "$1: no temp file or lock left in the state dir"
}

# ^ external a recording git first on PATH proves doctor ran no git at all
git_spy() {
    mkdir -p -- "$SANDBOX/spy" || return 1
    rm -f -- "$SANDBOX/spy.log" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\necho "$PWD $*" >>%q\nexec %q "$@"\n' "$SANDBOX/spy.log" "$GIT" >"$SANDBOX/spy/git" || return 1
    chmod u+rwx,go+rx -- "$SANDBOX/spy/git" || return 1
    set_env PATH="$SANDBOX/spy:$SANDBOX/pathbin:$TEST_BASE_PATH"
}

# ^ invariant starts doctor with the sandbox environment in the background and sets BG_PID; $1 = output file, the rest = doctor arguments
gsg_bg() {
    local out="$1"
    shift
    env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GSG_PROJECT/bin/git-secret-guard" doctor "$@" >"$out" 2>&1 &
    BG_PID=$!
}

# ^ invariant ends a background holder; it may already have exited
stop_holder() {
    kill "$1" 2>/dev/null || true
    wait "$1" 2>/dev/null || true
}

test_a_full_run_records_its_problems_and_nothing_else() {
    local content
    dr_begin && dr_repo off && dr_repo fw || return 1
    dr_disable off || return 1
    printf 'repos: []\n' >"$DR_ROOTS/fw/.pre-commit-config.yaml" || return 1
    (cd -- "$DR_ROOTS/fw" && commit_ignore_file "**   # a reason") || return 1
    doctor
    assert_rc 1 "one disabled repository"
    assert_contains "$OUT" "WARNING  .secret-scan-ignore line 1" "the run printed a WARNING"
    assert_contains "$OUT" "info     .pre-commit-config.yaml is present" "and an info line"
    assert_valid_record "after a full run"
    content="$(<"$(rec_file)")"
    assert_eq "$(rec_body)" "repo${TAB}$DR_REAL/off${TAB}-${TAB}$(off_text off)" "exactly the PROBLEM text doctor printed, scope = the repository"
    assert_not_contains "$content" "WARNING" "no warning is recorded"
    assert_not_contains "$content" "pre-commit" "no info is recorded"
    assert_not_contains "$content" "$DR_REAL/fw" "the repository with only a warning and an info is not recorded"
}

test_machine_problems_are_recorded_as_machine_scope() {
    dr_begin || return 1
    chmod -x "$LC_DATA/hooks/secret-scan" || return 1
    doctor
    assert_rc 1 "an unusable hook command"
    assert_valid_record "machine record"
    assert_eq "$(rec_body)" "machine${TAB}hook: hook command is missing or not executable ($LC_DATA/hooks/secret-scan); run git-secret-guard install" "scope machine and the printed text"
}

test_a_clean_full_run_empties_the_record() {
    dr_begin && dr_repo fine || return 1
    write_record "repo${TAB}$DR_REAL/fine${TAB}-${TAB}$(off_text fine)" "machine${TAB}some old machine problem" || return 1
    doctor
    assert_rc 0 "everything is fixed"
    assert_valid_record "after a clean run"
    assert_empty "$(rec_body)" "the record holds no findings"
}

test_roots_replaces_only_its_own_part_of_the_record() {
    dr_begin && dr_repo dev/a && dr_repo work/b || return 1
    dr_disable dev/a && dr_disable work/b || return 1
    doctor
    assert_rc 1 "both disabled"
    assert_contains "$(rec_body)" "$DR_REAL/work/b" "b is recorded"
    dr_enable work/b || return 1
    gsg doctor --roots "$DR_ROOTS/work"
    assert_rc 0 "nothing under work"
    assert_valid_record "after a partial run"
    assert_eq "$(rec_body)" "repo${TAB}$DR_REAL/dev/a${TAB}-${TAB}$(off_text dev/a)" "the record for dev/a is kept and the one for work/b is gone"
}

test_recheck_drops_what_was_fixed_and_keeps_what_is_not() {
    dr_begin && dr_repo a && dr_repo b && dr_repo c || return 1
    dr_disable a && dr_disable b || return 1
    doctor
    assert_rc 1 "a and b disabled"
    dr_enable a && dr_disable c || return 1
    recheck
    assert_rc 1 "b remains"
    assert_eq "$OUT" "repos with findings:
  $DR_REAL/b
    PROBLEM  $(off_text b)" "only b is printed"
    assert_valid_record "after recheck"
    assert_eq "$(rec_body)" "repo${TAB}$DR_REAL/b${TAB}-${TAB}$(off_text b)" "only b remains in the record, c was never inspected"
}

test_recheck_has_no_count_limit() {
    local i n
    dr_begin || return 1
    for i in $(seq 1 "$MANY_REPOS"); do dr_repo "r$i" && dr_disable "r$i" || return 1; done
    doctor
    assert_rc 1 "many broken repositories"
    assert_eq "$(rec_body | wc -l | tr -d ' ')" "$MANY_REPOS" "all of them recorded"
    recheck
    assert_rc 1 "still broken"
    n="$(grep -c 'PROBLEM  disabled in local config' <<<"$OUT")"
    assert_eq "$n" "$MANY_REPOS" "every one of them was re-checked and printed"
    assert_eq "$(rec_body | wc -l | tr -d ' ')" "$MANY_REPOS" "and every one is still recorded"
}

# ^ invariant $1 = what the record is; a recheck exits 0 with an empty stdout
recheck_prints_nothing() {
    recheck
    assert_rc 0 "$1"
    assert_empty "$OUT" "$1: prints nothing"
}

test_recheck_of_a_repository_that_no_longer_exists_drops_it_and_says_so_once() {
    dr_begin && dr_repo gone && dr_repo kept || return 1
    dr_disable gone && dr_disable kept || return 1
    doctor
    rm -rf -- "$DR_ROOTS/gone" || return 1
    recheck
    assert_rc 1 "kept still broken"
    assert_eq "$(grep -c 'no longer exists' <<<"$ERR")" 1 "one line says it is gone"
    assert_contains "$ERR" "$DR_REAL/gone no longer exists; dropped from the findings record" "naming the repository"
    assert_not_contains "$OUT" "gone" "stdout carries only what is still open"
    assert_eq "$(rec_body)" "repo${TAB}$DR_REAL/kept${TAB}-${TAB}$(off_text kept)" "only kept remains"
    rm -rf -- "$DR_ROOTS/kept" || return 1
    recheck_prints_nothing "nothing remains"
    assert_empty "$(rec_body)" "empty record"
}

test_a_directory_that_is_no_longer_a_repository_is_dropped_like_a_deleted_one() {
    dr_begin && dr_repo flat || return 1
    dr_disable flat || return 1
    doctor
    rm -rf -- "$DR_ROOTS/flat/.git" || return 1
    recheck_prints_nothing "no repository, no problem"
    assert_contains "$ERR" "$DR_REAL/flat no longer exists; dropped from the findings record" "the same line"
    assert_empty "$(rec_body)" "dropped"
}

test_recheck_with_no_record_or_an_empty_one_prints_nothing_and_runs_no_git() {
    dr_begin || return 1
    git_spy || return 1
    recheck_prints_nothing "no findings file"
    assert_no_file "$SANDBOX/spy.log" "no git ran"
    write_record || return 1
    recheck_prints_nothing "a record with no findings"
    : >"$(rec_file)" || return 1
    recheck_prints_nothing "a zero-byte file"
    assert_no_file "$SANDBOX/spy.log" "still no git"
}

# ^ invariant $1 = a kind of tampering; the record is written accordingly, DR_REAL/off being a real repository
tamper_record() {
    case "$1" in
        malformed) write_record "garbage line" ;;
        relative) write_record "repo${TAB}relative/path${TAB}-${TAB}text" ;;
        control) write_record "repo${TAB}$DR_REAL/off${TAB}-${TAB}text with a bell $(printf '\007')" ;;
        header) printf 'something else\ntime 2026-01-01T00:00:00Z\n' >"$(rec_file)" ;;
        time) printf '%s\ntime yesterday\n' "$REC_MAGIC" >"$(rec_file)" ;;
        notab) write_record "repo $DR_REAL/off - text" ;;
        abstree) write_record "repo${TAB}$DR_REAL/off${TAB}wt${TAB}text" ;;
        empty) write_record "machine${TAB}" ;;
        *) return 1 ;;
    esac
}

test_a_tampered_record_is_reported_not_trusted_and_the_next_full_run_replaces_it() {
    local kind
    dr_begin && dr_repo off || return 1
    git_spy || return 1
    for kind in malformed relative control header time notab abstree empty; do
        tamper_record "$kind" || return 1
        cp -- "$(rec_file)" "$SANDBOX/tampered.$kind" || return 1
        recheck
        assert_rc 2 "$kind: invalid record"
        assert_contains "$ERR" "the findings record $(rec_file) is invalid" "$kind: says so"
        assert_contains "$ERR" "run git-secret-guard doctor to replace it" "$kind: says what to do"
        assert_empty "$OUT" "$kind: prints no findings"
        assert_eq "$(<"$(rec_file)")" "$(<"$SANDBOX/tampered.$kind")" "$kind: the record is left as it was"
        assert_no_file "$SANDBOX/spy.log" "$kind: nothing in it was acted on"
    done
    dr_disable off || return 1
    doctor
    assert_rc 1 "a full run"
    assert_valid_record "replaced"
    assert_contains "$(rec_body)" "$DR_REAL/off" "by a valid record"
}

test_a_record_that_is_not_a_regular_file_is_invalid() {
    dr_begin || return 1
    mkdir -p -- "$LC_STATE" "$SANDBOX/elsewhere" || return 1
    write_record "machine${TAB}x" || return 1
    mv -- "$(rec_file)" "$SANDBOX/elsewhere/real" && ln -s "$SANDBOX/elsewhere/real" "$(rec_file)" || return 1
    recheck
    assert_rc 2 "a symlink"
    assert_contains "$ERR" "(not a regular file)" "says why"
    rm -f -- "$(rec_file)" && mkdir -- "$(rec_file)" || return 1
    recheck
    assert_rc 2 "a directory"
    assert_contains "$ERR" "(not a regular file)" "says why"
}

test_recheck_exit_status_is_0_when_clean_1_when_a_problem_remains_2_when_it_cannot_run() {
    dr_begin && dr_repo off || return 1
    dr_disable off || return 1
    doctor
    recheck
    assert_rc 1 "a PROBLEM remains"
    lc_fake_git "$OLD_GIT_VERSION" || return 1
    recheck
    assert_rc 2 "git too old to judge"
    assert_contains "$ERR" "doctor needs git >= 2.54" "says why"
    assert_empty "$OUT" "no report"
    assert_contains "$(rec_body)" "$DR_REAL/off" "and the record is untouched"
    rm -f -- "$SANDBOX/pathbin/git" || return 1
    dr_enable off || return 1
    recheck_prints_nothing "fixed"
}

test_recheck_replaces_a_changed_problem_with_the_new_one() {
    dr_begin && dr_repo chg || return 1
    dr_disable chg || return 1
    doctor
    dr_enable chg && gitx -C "$DR_ROOTS/chg" config hook.git-secret-guard.command /bin/true || return 1
    recheck
    assert_rc 1 "a different PROBLEM now"
    assert_contains "$OUT" "command overridden in local config" "the new one is printed"
    assert_not_contains "$OUT" "disabled in local config" "the old one is not"
    assert_valid_record "changed"
    assert_contains "$(rec_body)" "command overridden in local config" "the record holds the new one"
    assert_not_contains "$(rec_body)" "disabled in local config" "and not the old one"
}

test_recheck_reruns_the_machine_checks_and_prints_what_is_still_broken() {
    dr_begin || return 1
    chmod -x "$LC_DATA/hooks/secret-scan" || return 1
    doctor
    recheck
    assert_rc 1 "still broken"
    assert_eq "$OUT" "machine:
  PROBLEM  hook: hook command is missing or not executable ($LC_DATA/hooks/secret-scan); run git-secret-guard install" "only the machine PROBLEM, no ok lines"
    chmod +x "$LC_DATA/hooks/secret-scan" || return 1
    recheck_prints_nothing "fixed"
    assert_empty "$(rec_body)" "machine record dropped"
}

test_recheck_checks_the_recorded_worktrees_too() {
    dr_begin && dr_repo wtmain || return 1
    gitx -C "$DR_ROOTS/wtmain" worktree add -q "$DR_ROOTS/wt" -b wt || return 1
    gitx -C "$DR_ROOTS/wtmain" config extensions.worktreeConfig true || return 1
    gitx -C "$DR_ROOTS/wt" config --worktree hook.git-secret-guard.enabled false || return 1
    doctor
    assert_rc 1 "the worktree switches the hook off"
    assert_contains "$(rec_body)" "repo${TAB}$DR_REAL/wtmain${TAB}$DR_REAL/wt${TAB}worktree $DR_REAL/wt: disabled in worktree config" "the worktree is part of the record"
    recheck
    assert_rc 1 "still off"
    assert_contains "$OUT" "worktree $DR_REAL/wt: disabled in worktree config" "re-checked in the worktree"
    gitx -C "$DR_ROOTS/wt" config --worktree --unset hook.git-secret-guard.enabled || return 1
    recheck_prints_nothing "fixed"
    assert_empty "$(rec_body)" "dropped"
}

test_a_repository_path_the_record_cannot_hold_is_reported_not_silently_lost() {
    local odd=$'odd\nname'
    dr_begin && dr_repo "$odd" && dr_disable "$odd" || return 1
    doctor
    assert_rc 1 "a problem in a repository with a newline in its path"
    assert_contains "$ERR" "not recorded" "stderr says the record cannot hold it"
    assert_valid_record "the record stays valid"
    assert_empty "$(rec_body)" "and holds nothing for it"
}

test_a_full_run_that_cannot_finish_leaves_the_record_alone() {
    dr_begin && dr_repo off || return 1
    write_record "repo${TAB}$DR_REAL/off${TAB}-${TAB}$(off_text off)" || return 1
    cp -- "$(rec_file)" "$SANDBOX/before" || return 1
    gsg doctor --roots "$SANDBOX/no-such-dir"
    assert_rc 2 "a root that is not a directory"
    assert_eq "$(<"$(rec_file)")" "$(<"$SANDBOX/before")" "the record is as it was"
}

test_a_full_run_creates_the_state_dir_when_the_machine_is_not_installed() {
    dr_begin || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    rm -rf -- "$LC_STATE" || return 1
    doctor
    assert_rc 1 "not installed is a PROBLEM"
    assert_valid_record "recorded without a state dir"
    assert_contains "$(rec_body)" "installed: not installed" "the machine PROBLEM"
}

test_a_lock_left_by_a_dead_process_is_broken() {
    dr_begin && dr_repo off || return 1
    dr_disable off || return 1
    ln -s "$DEAD_PID" "$LC_STATE/findings.lock" || return 1
    doctor
    assert_rc 1 "a lock left by a dead process"
    assert_valid_record "the stale lock was broken"
}

test_a_lock_held_by_a_live_process_is_waited_for_then_refused() {
    local holder setup_failed=0 live_rc
    dr_begin && dr_repo off || return 1
    dr_disable off || return 1
    sleep "$HOLDER_SECONDS" &
    holder=$!
    # ^ why a stand-in sleep, not a production setting; the wait is a fixed number of attempts and the stand-in makes each of them instant
    if printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/pathbin/sleep" && chmod u+rwx,go+rx -- "$SANDBOX/pathbin/sleep" && ln -s "$holder" "$LC_STATE/findings.lock"; then
        doctor
        live_rc=$RC
    else
        setup_failed=1
    fi
    stop_holder "$holder"
    if [ "$setup_failed" -ne 0 ]; then
        fail "could not set up the live lock"
        return 1
    fi
    assert_eq "$live_rc" 2 "a lock held by a live process"
    assert_contains "$ERR" "holds $LC_STATE/findings.lock (process $holder)" "names the lock and its holder"
    assert_no_file "$(rec_file)" "nothing was written"
    [ -L "$LC_STATE/findings.lock" ] || fail "the other holder's lock is not ours to remove"
}

test_concurrent_full_runs_and_rechecks_always_leave_a_valid_record() {
    local i rc bad=0
    local -a pids=()
    dr_begin && dr_repo one && dr_repo two || return 1
    dr_disable one && dr_disable two || return 1
    doctor
    assert_rc 1 "the first full run"
    for i in $(seq 1 "$CONCURRENT_PAIRS"); do
        gsg_bg "$SANDBOX/full.$i" --roots "$DR_ROOTS"
        pids+=("$BG_PID")
        gsg_bg "$SANDBOX/re.$i" --recheck
        pids+=("$BG_PID")
    done
    for i in "${pids[@]}"; do
        wait "$i"
        rc=$?
        if [ "$rc" -ne 1 ]; then bad=$((bad + 1)); fi
    done
    assert_eq "$bad" 0 "every concurrent run finished with the expected status 1"
    assert_valid_record "after the concurrent runs"
    assert_eq "$(rec_body | LC_ALL=C sort)" "repo${TAB}$DR_REAL/one${TAB}-${TAB}$(off_text one)
repo${TAB}$DR_REAL/two${TAB}-${TAB}$(off_text two)" "a valid, complete file (the lock itself is proven by the racing-roots test)"
}

# ^ invariant $1 = a repository name under the roots; prints its record line as a full run would write it
repo_line() { printf 'repo%s%s/%s%s-%s%s' "$TAB" "$DR_REAL" "$1" "$TAB" "$TAB" "$(off_text "$1")"; }

test_a_full_run_keeps_recorded_repos_it_could_not_have_seen_under_its_roots() {
    local deep nm=node_modules/pkg locked=locked/inner rc
    deep="$(deep_path dev)/deep"
    dr_begin && dr_repo "$deep" && dr_repo "$nm" && dr_repo "$locked" && dr_repo gone || return 1
    write_record "$(repo_line "$deep")" "$(repo_line "$nm")" "$(repo_line "$locked")" "$(repo_line gone)" || return 1
    rm -rf -- "$DR_ROOTS/gone" || return 1
    chmod 000 "$DR_ROOTS/locked" || return 1
    doctor
    rc=$RC
    chmod 755 "$DR_ROOTS/locked" || return 1
    assert_eq "$rc" 1 "the unreadable directory is a PROBLEM"
    assert_valid_record "after the full run"
    assert_eq "$(rec_body)" "$(repo_line "$deep")
$(repo_line "$locked")
$(repo_line "$nm")" "repos too deep, below an unreadable dir and under node_modules are kept, the deleted one is gone"
}

test_an_invalid_record_contributes_nothing_to_a_full_run() {
    dr_begin && dr_repo fine || return 1
    write_record "repo${TAB}$SANDBOX/outside/forged${TAB}-${TAB}forged problem" "garbage line" || return 1
    doctor
    assert_rc 0 "nothing is wrong"
    assert_valid_record "after the full run"
    assert_empty "$(rec_body)" "the valid line before the bad one did not survive"
}

OLD_STAMP=202001010000
BLOCK_BYTES=1024

test_a_lock_held_by_a_live_pid_but_older_than_a_minute_is_stale() {
    local holder setup_failed=0 live_rc=""
    dr_begin && dr_repo off || return 1
    dr_disable off || return 1
    sleep "$HOLDER_SECONDS" &
    holder=$!
    if ln -s "$holder" "$LC_STATE/findings.lock" && touch -h -t "$OLD_STAMP" "$LC_STATE/findings.lock"; then
        doctor
        live_rc=$RC
    else
        setup_failed=1
    fi
    kill -0 "$holder" 2>/dev/null || fail "the holder process should still be alive, only the lock is old"
    stop_holder "$holder"
    if [ "$setup_failed" -ne 0 ]; then
        fail "could not set up the aged lock"
        return 1
    fi
    assert_eq "$live_rc" 1 "an aged lock does not block the run (a reused pid cannot hold it forever)"
    assert_valid_record "the aged lock was taken over"
}

test_a_record_over_the_byte_limit_is_invalid() {
    dr_begin || return 1
    mkdir -p -- "$LC_STATE" || return 1
    dd if=/dev/zero bs="$BLOCK_BYTES" count="$((RECORD_BYTE_LIMIT / BLOCK_BYTES + 1))" 2>/dev/null | tr '\0' x >"$(rec_file)" || return 1
    recheck
    assert_rc 2 "too many bytes"
    assert_contains "$ERR" "(more than $RECORD_BYTE_LIMIT bytes)" "says why, before reading the file"
}

test_a_full_run_removes_stale_temp_files_of_a_killed_run_and_keeps_a_fresh_one() {
    dr_begin && dr_repo off || return 1
    dr_disable off || return 1
    : >"$LC_STATE/findings.AbCdEf" && touch -t "$OLD_STAMP" "$LC_STATE/findings.AbCdEf" && : >"$LC_STATE/findings.ZyXwVu" || return 1
    doctor
    assert_rc 1 "a disabled repository"
    assert_no_file "$LC_STATE/findings.AbCdEf" "the old temp file of a killed run is gone"
    assert_file "$LC_STATE/findings.ZyXwVu" "a fresh one could belong to a live writer and stays"
    assert_contains "$(rec_body)" "$DR_REAL/off" "the record was written"
}

test_recheck_keeps_the_time_of_the_last_full_run() {
    local stamp="time 2026-01-01T00:00:00Z"
    dr_begin && dr_repo off || return 1
    dr_disable off || return 1
    write_record "$(repo_line off)" || return 1
    recheck
    assert_rc 1 "still disabled"
    assert_eq "$(sed -n 2p "$(rec_file)")" "$stamp" "a recheck rewrites the findings but not the time of the last full search"
    doctor
    assert_valid_record "after a full run"
    assert_not_contains "$(sed -n 2p "$(rec_file)")" "2026-01-01" "a full run stamps its own time"
}

WRITE_DELAY_SECONDS=2

# ^ invariant a date stand-in first on the sandbox PATH delays doctor's record write and logs held or free by the lock link at the call
# ^ coupled with lib/doctor_findings.sh:doctor_rec_write, running date after the old record was read and before the rename, under the lock
slow_date() {
    local real log="$SANDBOX/date.log"
    real="$(command -v date)" || return 1
    rm -f -- "$log" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ -L %q ]; then echo held >>%q; else echo free >>%q; fi\nsleep %s\nexec %q "$@"\n' \
        "$LC_STATE/findings.lock" "$log" "$log" "$WRITE_DELAY_SECONDS" "$real" >"$SANDBOX/pathbin/date" || return 1
    chmod u+rwx,go+rx -- "$SANDBOX/pathbin/date"
}

test_concurrent_runs_over_different_roots_keep_both_sets() {
    local i rc bad=0 name outs=""
    local -a pids=() files=()
    dr_begin && slow_date || return 1
    for name in dev/a1 dev/a2 work/b1 work/b2; do dr_repo "$name" && dr_disable "$name" || return 1; done
    for i in $(seq 1 "$CONCURRENT_PAIRS"); do
        gsg_bg "$SANDBOX/dev.$i" --roots "$DR_ROOTS/dev"
        pids+=("$BG_PID") files+=("$SANDBOX/dev.$i")
        gsg_bg "$SANDBOX/work.$i" --roots "$DR_ROOTS/work"
        pids+=("$BG_PID") files+=("$SANDBOX/work.$i")
    done
    for i in "${!pids[@]}"; do
        wait "${pids[$i]}"
        rc=$?
        if [ "$rc" -ne 1 ]; then
            bad=$((bad + 1))
            outs+=" [status $rc: $(tail -n 3 -- "${files[$i]}" | tr '\n' '|')]"
        fi
    done
    assert_eq "$bad" 0 "every run finished with status 1;$outs"
    assert_valid_record "after the racing runs"
    assert_eq "$(rec_body)" "$(repo_line dev/a1)
$(repo_line dev/a2)
$(repo_line work/b1)
$(repo_line work/b2)" "both sets survive; without the lock one run's write overwrites the other's"
    assert_not_contains "$(<"$SANDBOX/date.log")" "free" "doctor never wrote the record outside the lock"
    assert_contains "$(<"$SANDBOX/date.log")" "held" "and the write window was really observed under it"
}

# shellcheck source=lib/common.sh
source "$GSG_PROJECT/lib/common.sh"
# shellcheck source=lib/doctor_findings.sh
source "$GSG_PROJECT/lib/doctor_findings.sh"

MIB=1048576
TIME_LINE_BYTES=26

# ^ invariant runs doctor_rec_write of the project library against the sandbox state dir with DR_REC_BODY as the caller set it; stderr goes to write.err
run_writer() {
    (
        GSG_NAME=git-secret-guard GSG_STATE_DIR="$LC_STATE" GSG_FINDINGS_FILE="$LC_STATE/findings"
        doctor_rec_write 2>"$SANDBOX/write.err"
    )
}

# ^ invariant runs doctor_rec_read of the project library on the sandbox record; stderr goes to read.err
read_record() {
    (
        GSG_NAME=git-secret-guard GSG_FINDINGS_FILE="$LC_STATE/findings"
        doctor_rec_read 2>"$SANDBOX/read.err"
    )
}

# ^ invariant $1 = EXTRA; sets DR_REC_BODY for a written file of the line limit plus EXTRA lines, the two header lines included
body_of_lines() {
    local i n=$((GSG_FINDINGS_MAX_LINES - GSG_FINDINGS_HEADER_LINES + $1))
    DR_REC_BODY=()
    for ((i = 0; i < n; i++)); do DR_REC_BODY+=("machine${TAB}m$i"); done
}

# ^ invariant $1 = EXTRA; sets DR_REC_BODY for a written file of the byte limit plus EXTRA bytes, as lines of one MiB and a last one for the rest
body_of_bytes() {
    local big header rest k i p last_len
    big="$(head -c "$MIB" /dev/zero | tr '\0' x)" || return 1
    header=$((${#GSG_FINDINGS_MAGIC} + 1 + TIME_LINE_BYTES))
    rest=$((GSG_FINDINGS_MAX_BYTES + $1 - header))
    k=$((rest / (MIB + 1)))
    DR_REC_BODY=()
    for ((i = 0; i < k; i++)); do
        p="machine${TAB}$i."
        DR_REC_BODY+=("$p${big:0:$((MIB - ${#p}))}")
    done
    last_len=$((rest - k * (MIB + 1) - 1))
    p="machine${TAB}last."
    DR_REC_BODY+=("$p${big:0:$((last_len - ${#p}))}")
}

RECORD_LINE_LIMIT=$GSG_FINDINGS_MAX_LINES
RECORD_BYTE_LIMIT=$GSG_FINDINGS_MAX_BYTES

test_recheck_keeps_a_recorded_repo_and_worktree_it_cannot_reach_and_says_so() {
    local before rc
    dr_begin && dr_repo locked/inner && dr_repo wtmain || return 1
    dr_disable locked/inner || return 1
    gitx -C "$DR_ROOTS/wtmain" worktree add -q "$DR_ROOTS/locked/wt" -b wt || return 1
    gitx -C "$DR_ROOTS/wtmain" config extensions.worktreeConfig true || return 1
    gitx -C "$DR_ROOTS/locked/wt" config --worktree hook.git-secret-guard.enabled false || return 1
    doctor
    assert_rc 1 "both are recorded by the full run"
    before="$(rec_body)"
    chmod 000 "$DR_ROOTS/locked" || return 1
    recheck
    rc=$RC
    chmod 755 "$DR_ROOTS/locked" || return 1
    assert_eq "$rc" 1 "a PROBLEM remains that could not be re-checked"
    assert_contains "$OUT" "$(off_text locked/inner)" "the unreachable repository is printed as still open"
    assert_contains "$OUT" "worktree $DR_REAL/locked/wt: disabled in worktree config" "and so is the unreachable worktree"
    assert_contains "$ERR" "$DR_REAL/locked/inner cannot be reached; kept in the findings record" "one note for the repository"
    assert_contains "$ERR" "$DR_REAL/locked/wt cannot be reached; kept in the findings record" "one note for the worktree"
    assert_not_contains "$ERR" "no longer exists" "nothing is claimed gone that is only out of sight"
    assert_eq "$(rec_body)" "$before" "the record is unchanged"
}

test_a_record_over_the_line_limit_is_invalid() {
    dr_begin || return 1
    mkdir -p -- "$LC_STATE" || return 1
    awk -v magic="$REC_MAGIC" -v n="$RECORD_LINE_LIMIT" 'BEGIN { print magic; print "time 2026-01-01T00:00:00Z"; for (i = 0; i < n; i++) print "machine\tx" }' >"$(rec_file)" || return 1
    recheck
    assert_rc 2 "too many lines"
    assert_contains "$ERR" "(more than $RECORD_LINE_LIMIT lines)" "says why"
}

# ^ why a source check, not stand-ins on PATH; the probes are bash builtins no stand-in can observe and find, wc and date are allowed under the lock
test_the_functions_that_run_under_the_lock_probe_no_directory() {
    local fn body
    for fn in doctor_rec_replaced doctor_rec_commit doctor_rec_write doctor_rec_clean_temps; do
        body="$(awk -v f="$fn" 'index($0, f "() {") == 1 { on = 1 } on { print } on && $0 == "}" { exit }' "$GSG_PROJECT/lib/doctor_findings.sh")"
        [ -n "$body" ] || fail "$fn was not found"
        assert_not_contains "$body" "doctor_rec_proven_gone" "$fn does not stat ancestors under the lock"
        assert_not_contains "$body" "doctor_rec_present" "$fn does not probe the repository under the lock"
    done
}

# ^ invariant $1 = body helper, $2 = the limit as the message words it; one unit over the limit is refused, the old record and the state dir stay as they were
assert_writer_refuses_over_limit() {
    local rc
    dr_begin && write_record "machine${TAB}old" && cp -- "$(rec_file)" "$SANDBOX/old" || return 1
    "$1" 1 || return 1
    run_writer
    rc=$?
    assert_eq "$rc" 1 "$2 plus one is refused"
    assert_eq "$(cksum <"$(rec_file)")" "$(cksum <"$SANDBOX/old")" "$2: the old record is byte-identical"
    assert_empty "$(find "$LC_STATE" -mindepth 1 -name 'findings.??????')" "$2: no temp file stays"
    assert_contains "$(<"$SANDBOX/write.err")" "the findings record would exceed $2; the previous record is kept" "$2: says why"
}

# ^ invariant $1 = body helper, $2 = the wc flag counting the unit, $3 = the limit; exactly the limit is written and the reader accepts it
assert_writer_accepts_at_limit() {
    local rc
    dr_begin || return 1
    "$1" 0 || return 1
    run_writer
    rc=$?
    assert_eq "$rc" 0 "exactly the limit is written"
    assert_eq "$(wc "$2" <"$(rec_file)" | tr -d ' ')" "$3" "the file has exactly the limit"
    read_record
    rc=$?
    assert_eq "$rc" 0 "and the reader accepts it ($(<"$SANDBOX/read.err"))"
}

test_the_writer_refuses_a_record_over_the_line_limit_and_keeps_the_old_one() {
    assert_writer_refuses_over_limit body_of_lines "$GSG_FINDINGS_MAX_LINES lines"
}

test_the_writer_accepts_exactly_the_line_limit_and_the_reader_accepts_it() {
    assert_writer_accepts_at_limit body_of_lines -l "$GSG_FINDINGS_MAX_LINES"
}

test_the_writer_refuses_a_record_over_the_byte_limit_and_keeps_the_old_one() {
    assert_writer_refuses_over_limit body_of_bytes "$GSG_FINDINGS_MAX_BYTES bytes"
}

test_the_writer_accepts_exactly_the_byte_limit_and_the_reader_accepts_it() {
    assert_writer_accepts_at_limit body_of_bytes -c "$GSG_FINDINGS_MAX_BYTES"
}

test_a_full_run_that_replaces_an_invalid_record_says_it_is_replacing_it() {
    dr_begin && dr_repo fine || return 1
    write_record "garbage line" || return 1
    doctor
    assert_rc 0 "nothing is wrong"
    assert_contains "$ERR" "is invalid (line 3 is malformed); replacing it" "the full run says what it does"
    assert_not_contains "$ERR" "to replace it" "and does not tell the user to run what is running"
    assert_valid_record "replaced"
}

run_file_tests
