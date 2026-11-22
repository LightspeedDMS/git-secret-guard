#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2016
# ^ invariant real git, a bare file origin, annotated tags, the real update cycle; no systemd (units in tests/autoupdate/test_autoupdate_units.sh)
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

# shellcheck source=tests/autoupdate/autoupdate.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/autoupdate.sh"
AU_TEMPLATE=1

test_the_role_is_a_pure_function_of_the_two_paths() {
    local base="$SANDBOX/role"
    lc_begin || return 1
    # ^ why a real repository, not an empty .git directory; under MSYS the owner is asked of git itself
    rm -rf -- "$base" && mkdir -p -- "$base/file" "$base/none" && gitx init -q "$base/own" || return 1
    printf 'gitdir: elsewhere\n' >"$base/file/.git" || return 1
    au_lib "$GSG_PROJECT" 'lifecycle_require_git; autoupdate_role "$1"' "$base/own"
    assert_rc 0 "a checkout and a .git directory of this user"
    assert_eq "$OUT" owner "both paths are owned by this user"
    au_lib "$GSG_PROJECT" 'autoupdate_role "$1"' "$base/file"
    assert_rc 1 "a .git file (worktree or submodule)"
    assert_empty "$OUT" "no role for a .git file"
    au_lib "$GSG_PROJECT" 'autoupdate_role "$1"' "$base/none"
    assert_rc 1 "no .git at all"
    au_lib "$GSG_PROJECT" 'autoupdate_role "$1"' /
    assert_rc 1 "the root directory is not a checkout"
}

# ^ why a test of its own, not a branch of the role test; skip_test would hide the assertions before it, and a run owning /usr shows SKIPPED
test_a_git_directory_of_another_user_is_a_follower() {
    local base="$SANDBOX/role-foreign"
    lc_begin || return 1
    if [ -O /usr ]; then skip_test "this user owns /usr (root, or a shell that cannot tell owners), so there is no .git directory of another user to point at"; fi
    rm -rf -- "$base" && mkdir -p -- "$base/foreign" && ln -s /usr "$base/foreign/.git" || return 1
    au_lib "$GSG_PROJECT" 'autoupdate_role "$1"' "$base/foreign"
    assert_rc 0 "a .git directory of another user"
    assert_eq "$OUT" follower "the .git directory is owned by root"
}

test_needs_install_compares_with_the_state_and_with_the_installed_copy() {
    local share="$SANDBOX/needs-share" state shared x want
    lc_begin || return 1
    rm -rf -- "$share" && mkdir -p -- "$share" || return 1
    while IFS='|' read -r state shared x want; do
        printf '%s\n' "$shared" >"$share/VERSION" || return 1
        au_lib "$GSG_PROJECT" 'ST_VERSION="$1"; GSG_SHARE="$2"; autoupdate_needs_install "$3"' "$state" "$share" "$x"
        assert_rc "$want" "state [$state] share [$shared] target [$x]"
    done <<'EOF'
1.0.0|1.0.0|1.0.1|0
1.0.0|1.0.0|1.0.0|1
1.0.0|1.0.0|0.9.9|1
1.9.0|1.9.0|1.10.0|0
1.10.0|1.10.0|1.9.0|1
1.1.0|1.0.0|1.1.0|0
1.0.0|1.1.0|1.1.0|0
1.1.0|1.1.0|1.1.0|1
0.8.0|0.8.0|0.08.1|0
1.0.0|1.0.0|1.x.0|2
1.0.0|1.0.0|1.0|2
1.x.0|1.0.0|1.1.0|2
1.0.0|garbage|1.1.0|2
EOF
    rm -f -- "$share/VERSION" || return 1
    au_lib "$GSG_PROJECT" 'ST_VERSION="$1"; GSG_SHARE="$2"; autoupdate_needs_install "$3"' 1.0.0 "$share" 1.0.0
    assert_rc 0 "an installed copy without a VERSION file needs the install"
}

test_a_free_or_dead_update_lock_is_taken_and_released() {
    local dead
    lc_begin || return 1
    au_lib "$GSG_PROJECT" "$AU_TAKE"'; autoupdate_lock_release; echo "release=$?"; if [ -L "$GSG_UPDATE_LOCK" ]; then echo still; else echo gone; fi'
    assert_contains "$OUT" "take=0 link=" "a free lock is taken, also when the state dir did not exist"
    [[ $OUT =~ link=([0-9]+)\ pid=([0-9]+) ]] && [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ] || fail "the lock names the taker's pid: $OUT"
    assert_contains "$OUT" $'release=0\ngone' "release removes the taker's own lock"
    true &
    dead=$!
    wait "$dead"
    ln -s "$dead" "$LC_STATE/update.lock" || return 1
    au_lib "$GSG_PROJECT" "$AU_TAKE"
    assert_contains "$OUT" "take=0" "a lock left by a dead process is broken"
    rm -f -- "$LC_STATE/update.lock"
}

# ^ why apart from the lock test, not inside it; NTFS has no modes and only this assertion is a Windows exception
test_the_state_dir_made_for_the_lock_is_private() {
    lc_begin || return 1
    au_lib "$GSG_PROJECT" "$AU_TAKE"'; autoupdate_lock_release'
    assert_contains "$OUT" "take=0" "the lock is taken"
    assert_eq "$(stat -c %a "$LC_STATE")" 700 "the state dir made for the lock is private"
}

# ^ invariant the checks against a lock held by live process $1; the caller stops this process whatever the checks return
au_live_holder_checks() {
    local holder="$1"
    ln -s "$holder" "$LC_STATE/update.lock" || return 1
    au_lib "$GSG_PROJECT" "$AU_TAKE"
    assert_contains "$OUT" "take=1 link=$holder " "a live holder refuses the lock at once, rc 1"
    assert_contains "$ERR" "another run holds $LC_STATE/update.lock (process $holder)" "names the lock and its holder"
    au_lib "$GSG_PROJECT" 'paths_init || exit 9; export GSG_UPDATE_LOCK_PID="$1"; autoupdate_lock_take; echo "take=$?"' "$holder"
    assert_contains "$OUT" "take=1" "the holder's pid in the environment lets no process in that is not its child"
    au_lib "$GSG_PROJECT" 'paths_init || exit 9; AU_LOCK_HELD=1; autoupdate_lock_release; if [ -L "$GSG_UPDATE_LOCK" ]; then echo still; fi'
    assert_contains "$OUT" still "a lock naming another process is not ours to remove"
    touch -h -d "$STALE_LOCK_AGE" "$LC_STATE/update.lock" || return 1
    au_lib "$GSG_PROJECT" "$AU_TAKE"
    assert_contains "$OUT" "take=0" "a lock older than any run is broken although its pid is alive (a reused pid)"
}

test_the_update_lock_refuses_a_live_holder_until_the_lock_is_older_than_any_run() {
    local holder
    lc_begin && mkdir -p -- "$LC_STATE" || return 1
    sleep "$HOLDER_SECONDS" &
    holder=$!
    au_live_holder_checks "$holder"
    stop_holder "$holder"
    rm -f -- "$LC_STATE/update.lock"
}

test_a_child_of_the_lock_holder_is_let_in_and_leaves_the_lock() {
    local child="$AU_PRELUDE"'paths_init || exit 9; autoupdate_lock_take; rc=$?; autoupdate_lock_release; exit "$rc"'
    lc_begin || return 1
    au_lib "$GSG_PROJECT" 'paths_init || exit 9; autoupdate_lock_take || exit 8
GSG_UPDATE_LOCK_PID=$$ "$2" "$3" bash -c "$1" _ "$GSG_ROOT"; echo "under-timeout=$?"
GSG_UPDATE_LOCK_PID=$$ bash -c "$1" _ "$GSG_ROOT"; echo "direct=$?"
bash -c "$1" _ "$GSG_ROOT" 2>/dev/null; echo "no-pid=$?"
GSG_UPDATE_LOCK_PID=1 bash -c "$1" _ "$GSG_ROOT" 2>/dev/null; echo "wrong-pid=$?"
if [ "$(readlink -- "$GSG_UPDATE_LOCK")" = "$$" ]; then echo parent-still-holds; fi
autoupdate_lock_release; echo "parent-release=$?"' "$child" "$TEST_TIMEOUT" "$CHILD_TIMEOUT_SECONDS"
    assert_rc 0 "the parent ran to the end"
    assert_contains "$OUT" "under-timeout=0" "the child install runs under timeout, its grandparent holds the lock"
    assert_contains "$OUT" "direct=0" "a direct child is let in"
    assert_contains "$OUT" "no-pid=1" "a child without the inherited pid is refused"
    assert_contains "$OUT" "wrong-pid=1" "a child with another pid is refused"
    assert_contains "$OUT" parent-still-holds "a child that was let in never removes its parent's lock"
    assert_contains "$OUT" "parent-release=0" "the parent releases its own lock"
    assert_no_file "$LC_STATE/update.lock" "no lock is left"
}

# ^ invariant origin gets v1.9.0 and v1.10.0 on main, an untagged commit after them, and three tags a release never is
# ^ invariant the three are a name outside vX.Y.Z (two of them), a VERSION file unlike the name (v9.9.9), and a tag not merged into main (v7.0.0)
au_owner_scene() {
    printf '#!/bin/sh\n: >"%s"\n' "$SANDBOX/au-child.post-merge" >"$AU_CO/.git/hooks/post-merge" && chmod 755 "$AU_CO/.git/hooks/post-merge" || return 1
    printf 'untracked\n' >"$AU_CO/lib/untracked-not-exported.txt" || return 1
    au_release 1.9.0 && au_release 1.10.0 || return 1
    gitx -C "$AU_SRC" tag v9.9.9 && gitx -C "$AU_SRC" tag v2.0.0-rc1 && gitx -C "$AU_SRC" tag v3.0 || return 1
    gitx -C "$AU_SRC" checkout -q -b side || return 1
    au_release 7.0.0 || return 1
    gitx -C "$AU_SRC" checkout -q main || return 1
    printf 'later\n' >"$AU_SRC/later.txt" && au_commit "$AU_SRC" "untagged work after the release" || return 1
    au_publish
}

assert_owner_record() {
    assert_eq "$(cut -d= -f1 "$LC_STATE/update" | tr '\n' ' ')" "checked_at role result reason detail from to " "the record holds exactly these keys in this order"
    [[ $(rec checked_at) =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || fail "checked_at is a UTC time: $(rec checked_at)"
    assert_eq "$(rec role)|$(rec result)|$(rec reason)|$(rec from)|$(rec to)" "owner|updated||1.0.0|1.10.0" "the record"
    assert_no_file "$LC_STATE/update.lock" "the lock is released"
    assert_eq "$(au_leftovers)" 0 "no work dir and no temp record is left"
}

# ^ why apart from the owner test, not inside it; NTFS has no modes and only this assertion is a Windows exception
test_the_update_record_is_private() {
    au_setup || return 1
    upd
    assert_rc 0 "an update with nothing newer"
    assert_eq "$(stat -c %a "$LC_STATE/update")" 600 "the record is private"
}

test_the_owner_moves_to_the_newest_released_tag_and_installs_from_its_export() {
    local tagged
    au_setup && au_owner_scene || return 1
    tagged="$(gitx -C "$AU_SRC" rev-parse 'refs/tags/v1.10.0^{commit}')" || return 1
    upd
    assert_rc 0 "update exits 0"
    assert_eq "$(gitx -C "$AU_CO" rev-parse HEAD)" "$tagged" "HEAD is exactly the commit of the highest valid tag, v1.10.0 above v1.9.0"
    assert_eq "$(gitx -C "$AU_CO" rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')" 2 "a fast-forward, no merge commit"
    assert_no_file "$AU_CO/later.txt" "the untagged commit after the tag is not merged"
    assert_eq "$(gitx -C "$AU_CO" symbolic-ref HEAD)" refs/heads/main "still on main"
    assert_file "$SANDBOX/au-child.post-merge" "the owner's own post-merge hook ran"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.10.0 "the installed copy is the tag's"
    assert_no_file "$LC_DATA/lib/untracked-not-exported.txt" "installed from the export of the tag, not from the work tree"
    assert_eq "$(state_value version)" 1.10.0 "the child install recorded the version"
    assert_eq "$(state_value auto_update)" yes "auto-update stays on"
    assert_eq "$(state_value source_checkout)" "$AU_CO" "an install from the export keeps the recorded checkout"
    assert_owner_record
    assert_contains "$OUT" "update: updated 1.0.0 -> 1.10.0" "says what happened"

    upd
    assert_rc 0 "a second run"
    assert_record current "" "nothing newer: current"
    assert_eq "$(gitx -C "$AU_CO" rev-parse HEAD)" "$tagged" "HEAD did not move"

    printf 'more\n' >>"$AU_SRC/later.txt" && au_commit "$AU_SRC" "only untagged commits" && au_publish || return 1
    upd
    assert_rc 0 "only untagged commits were pushed"
    assert_record current "" "untagged commits are not a release"
    assert_eq "$(gitx -C "$AU_CO" rev-parse HEAD)" "$tagged" "nothing was merged"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.10.0 "nothing was installed"
}

# ^ coupled lib/autoupdate/autoupdate.sh:GSG_UPDATE_VERSION_RE allows 1 to 9 digits a part; a longer tag version is invalid, the run goes on with the valid ones
test_a_tag_with_an_oversized_version_part_is_ignored_and_a_valid_newer_tag_installs() {
    au_setup || return 1
    au_release 99999999999999999999.0.0 && au_release 1.2.0 && au_publish || return 1
    upd
    assert_rc 0 "update exits 0"
    assert_record updated "" "the oversized tag is skipped like any invalid tag, the run is no bad-version"
    assert_eq "$(rec from)|$(rec to)" "1.0.0|1.2.0" "the valid tag is the target"
    assert_eq "$(gitx -C "$AU_CO" rev-parse HEAD)" "$(gitx -C "$AU_SRC" rev-parse 'refs/tags/v1.2.0^{commit}')" "HEAD is exactly v1.2.0"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.2.0 "1.2.0 is installed"
}

# ^ invariant an au_case_* function runs one group of skip cases on the au_setup_with_release setup and removes its obstacles before it returns
# ^ why the groups in one test, not one test each; a setup and a control install cost about 250 programs each
# ^ invariant a group records the checkout of the setup first; the group before it leaves another one recorded
au_case_doubtful_shape() {
    au_state source_checkout "$AU_CO" || return 1
    gitx -C "$AU_CO" checkout -q -b side || return 1
    au_skip_case not-on-main "$AU_CO"
    gitx -C "$AU_CO" checkout -q main && gitx -C "$AU_CO" branch -q -D side || return 1

    printf 'edited\n' >>"$AU_CO/lib/cli/usage.md" || return 1
    au_skip_case dirty "$AU_CO"
    gitx -C "$AU_CO" checkout -q -- lib/cli/usage.md || return 1

    au_clone shallow --depth 1 || return 1
    au_skip_case shallow "$SANDBOX/au-extra-shallow"

    au_skip_case checkout-missing "$SANDBOX/au-extra-gone" "$AU_CO"

    rm -rf -- "$SANDBOX/au-extra-worktree" && gitx -C "$AU_CO" worktree add -q -b wt "$SANDBOX/au-extra-worktree" || return 1
    au_skip_case not-a-plain-checkout "$SANDBOX/au-extra-worktree"
    assert_contains "$(rec detail)" ".git is not a directory or no repository" "the detail names both causes"
    gitx -C "$AU_CO" worktree remove --force "$SANDBOX/au-extra-worktree" && gitx -C "$AU_CO" branch -q -D wt || return 1
}

au_case_doubtful_origin() {
    local url gone detail
    au_state source_checkout "$AU_CO" || return 1
    gitx -C "$AU_CO" remote rename origin elsewhere || return 1
    au_skip_case no-origin "$AU_CO"
    gitx -C "$AU_CO" remote rename elsewhere origin || return 1

    url="$(gitx -C "$AU_CO" remote get-url origin)" || return 1
    gone="$(lc_file_url "$SANDBOX/au-no-such-origin.git")"
    gitx -C "$AU_CO" remote set-url origin "$gone" || return 1
    au_skip_case fetch-failed "$AU_CO"
    detail="$(rec detail)"
    assert_contains "$detail" "au-no-such-origin.git" "fetch-failed: the detail is git's first stderr line"
    [ "${#detail}" -le "$DETAIL_MAX" ] || fail "fetch-failed: the detail is at most $DETAIL_MAX characters, got ${#detail}"
    assert_eq "$(gitx -C "$AU_CO" remote get-url origin)" "$gone" "fetch-failed: the origin URL is not rewritten"
    gitx -C "$AU_CO" remote set-url origin "$url" || return 1

    au_clone ahead || return 1
    gitx -C "$SANDBOX/au-extra-ahead" reset -q --hard v1.0.0 || return 1
    printf 'local\n' >"$SANDBOX/au-extra-ahead/local.txt" && au_commit "$SANDBOX/au-extra-ahead" "a local commit the tag does not contain" || return 1
    au_skip_case ahead-of-tag "$SANDBOX/au-extra-ahead"
}

# ^ invariant the locked case against live process $1; the caller stops this process whatever the case returns
au_locked_case() {
    local holder="$1"
    ln -s "$holder" "$LC_STATE/update.lock" || return 1
    au_run_unchanged locked "$AU_CO" 0
    assert_record skipped locked "locked: the record"
    assert_eq "$(rec role)" owner "locked: the role is still recorded"
    assert_eq "$(readlink -- "$LC_STATE/update.lock")" "$holder" "locked: the other run's lock is not ours to remove"
}

au_case_held_lock_or_bad_version() {
    local holder
    au_state source_checkout "$AU_CO" || return 1
    au_state version 1.x.0 || return 1
    au_skip_case bad-version "$AU_CO"
    au_state version 1.0.0 || return 1

    sleep "$HOLDER_SECONDS" &
    holder=$!
    au_locked_case "$holder"
    stop_holder "$holder"
    rm -f -- "$LC_STATE/update.lock" || return 1
}

# ^ hazard ln -s PID DIR made DIR/PID and let the run in, a second run did the same => two runs, both skipped
au_case_directory_at_the_lock_path() {
    local run
    au_state source_checkout "$AU_CO" || return 1
    mkdir -- "$LC_STATE/update.lock" || return 1
    for run in first second; do
        au_run_unchanged "dir lock, $run run" "$AU_CO" 0
        assert_record skipped locked "dir lock, $run run: the record"
        assert_contains "$(rec detail)" "a directory, not a lock, is at $LC_STATE/update.lock" "dir lock, $run run: the detail starts with the reason and names the path"
        if [ ! -d "$LC_STATE/update.lock" ] || [ -L "$LC_STATE/update.lock" ]; then fail "dir lock, $run run: still a directory"; fi
        assert_empty "$(ls -A -- "$LC_STATE/update.lock")" "dir lock, $run run: nothing was made inside"
    done
    rmdir -- "$LC_STATE/update.lock" || return 1
}

au_case_auto_update_off() {
    au_state source_checkout "$AU_CO" || return 1
    au_state auto_update no || return 1
    au_run_unchanged "auto-update off" "$AU_CO" 0
    assert_contains "$OUT" "auto-update is off" "says it is off"
    assert_no_file "$LC_STATE/update" "auto-update off: no record is written"
    assert_no_file "$LC_STATE/update.lock" "auto-update off: no lock is left"
    au_state auto_update yes || return 1
}

# ^ invariant every skip group in turn and one installing update at the end; it proves each obstacle was the only thing in the way
# ^ why a failed assert, not a return, ends no group; the next group still runs and only a broken step stops the test
test_every_doubtful_case_is_skipped_and_nothing_changes() {
    au_setup_with_release || return 1
    au_case_doubtful_shape || return 1
    au_case_doubtful_origin || return 1
    au_case_held_lock_or_bad_version || return 1
    au_case_directory_at_the_lock_path || return 1
    au_case_auto_update_off || return 1
    au_control
}

# ^ external git applies the other ref updates of a fetch whose tag update it rejects (observed) => origin/main moves, au_skip_case's ref snapshot cannot hold
test_a_moved_tag_is_a_failed_fetch_and_the_local_tag_stays() {
    local tag head installed
    au_setup_with_release || return 1
    upd
    assert_record updated "" "the checkout fetched v1.1.0"
    tag="$(gitx -C "$AU_CO" rev-parse 'refs/tags/v1.1.0^{commit}')" && head="$(gitx -C "$AU_CO" rev-parse HEAD)" && installed="$(au_share_state)" || return 1
    printf 'moved\n' >"$AU_SRC/moved.txt" && au_commit "$AU_SRC" "the commit the tag is moved to" || return 1
    gitx -C "$AU_SRC" tag -f -a v1.1.0 -m moved >/dev/null && gitx -C "$AU_SRC" push -q --force origin main refs/tags/v1.1.0 || return 1
    upd
    assert_rc 0 "a moved tag is a skip, exit 0"
    assert_record skipped fetch-failed "the rejected tag update fails the fetch"
    assert_eq "$(gitx -C "$AU_CO" rev-parse 'refs/tags/v1.1.0^{commit}')" "$tag" "the local tag still names the first commit"
    assert_eq "$(gitx -C "$AU_CO" rev-parse HEAD)" "$head" "HEAD did not move"
    assert_empty "$(gitx -C "$AU_CO" status --porcelain)" "the work tree is untouched"
    assert_eq "$(au_share_state)" "$installed" "the installed copy and the state are unchanged"
    assert_no_file "$LC_STATE/update.lock" "the lock is released"
}

test_a_state_ahead_of_the_installed_copy_still_installs() {
    au_setup_with_release || return 1
    au_state version 1.1.0 || return 1
    upd
    assert_rc 0 "the state says 1.1.0, the installed copy is 1.0.0"
    assert_eq "$(rec result)|$(rec from)|$(rec to)" "updated|1.0.0|1.1.0" "the gap is closed by installing"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.1.0 "the installed copy caught up"
}

# ^ invariant release 1.1.0 on origin is one whose installer prints REFUSAL on stderr and exits 1
au_publish_refusing_release() {
    au_broken_installer "echo \"git-secret-guard: $REFUSAL\" >&2; exit 1" && au_release 1.1.0 && au_publish
}

test_a_failed_child_install_keeps_the_old_copy_and_the_next_run_retries() {
    local before
    au_setup && au_publish_refusing_release || return 1
    before="$(au_share_state)" || return 1
    upd
    assert_rc 1 "a failed install is an error, exit 1"
    assert_record failed install-failed "the record"
    assert_contains "$(rec detail)" "$REFUSAL" "the detail is the installer's first stderr line"
    assert_eq "$(rec from)|$(rec to)" "1.0.0|1.1.0" "from and to"
    assert_eq "$(au_share_state)" "$before" "the old copy and the state are untouched"
    assert_eq "$(<"$SANDBOX/au-child.args")" install "the child install gets no flags"
    assert_eq "$(tr -d ' ' <"$SANDBOX/au-child.stdin")" 0 "its stdin is /dev/null"
    [[ $(<"$SANDBOX/au-child.lockpid") =~ ^[0-9]+$ ]] || fail "the child inherits the lock holder's pid"
    assert_no_file "$LC_STATE/update.lock" "the lock is released after a failure"
    assert_eq "$(au_leftovers)" 0 "the export is removed after a failure"

    rm -f -- "$SANDBOX/au-child.args" || return 1
    upd
    assert_rc 1 "the next run retries and fails again"
    assert_file "$SANDBOX/au-child.args" "the installer was started again"
}

test_an_installer_that_exits_0_without_installing_is_a_failure_and_a_sound_release_recovers() {
    au_setup || return 1
    au_broken_installer 'exit 0' && au_release 1.1.0 && au_publish || return 1
    upd
    assert_rc 1 "an installer that exits 0 without installing"
    assert_record failed install-failed "exit 0 is not enough, the installed VERSION must be the target"
    assert_contains "$(rec detail)" "1.0.0" "the detail names the version found"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.0.0 "still the old copy"

    cp -- "$GSG_PROJECT/bin/git-secret-guard" "$AU_SRC/bin/git-secret-guard" && au_release 1.2.0 && au_publish || return 1
    upd
    assert_rc 0 "a sound release goes through after the broken one"
    assert_eq "$(rec result)|$(rec from)|$(rec to)" "updated|1.0.0|1.2.0" "recovered"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.2.0 "installed"
}

test_a_follower_installs_from_the_tag_export_and_never_fetches() {
    local head
    au_setup_follower_at_release || return 1
    au_release 1.2.0 && au_publish || return 1
    head="$(gitx -C "$AU_CO" rev-parse HEAD)" || return 1
    run_cap env -i "${LC_ENV[@]}" GIT_TEST_ASSUME_DIFFERENT_OWNER=1 "$GIT" -C "$AU_CO" rev-parse HEAD
    assert_rc 128 "control: without safe.directory git refuses the checkout of another user"
    assert_contains "$ERR" "dubious ownership" "control: for the ownership reason"

    upd_follower
    assert_rc 0 "the follower's update"
    assert_eq "$(rec role)|$(rec result)|$(rec reason)|$(rec from)|$(rec to)" "follower|updated||1.0.0|1.1.0" "the record"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.1.0 "the follower's own copy is the version at the checkout's HEAD"
    assert_eq "$(gitx -C "$AU_CO" rev-parse HEAD)" "$head" "the follower moved nothing in the checkout"
    assert_eq "$(gitx -C "$AU_CO" rev-parse -q --verify refs/tags/v1.2.0 | wc -l | tr -d ' ')" 0 "the follower did not fetch, v1.2.0 is still unknown here"
    assert_not_contains "$(gitx config --global --get-all safe.directory)" "$AU_CO" "safe.directory is never written to a config file"
}

test_a_follower_skips_a_head_that_is_not_a_release() {
    au_setup_follower_at_release || return 1
    printf '9.9.9\n' >"$AU_CO/VERSION" && au_commit "$AU_CO" "HEAD moves past the tag, to a version no tag names" || return 1
    upd_follower
    assert_rc 0 "HEAD is not at a tag"
    assert_record skipped not-at-tag "nothing is installed from an untagged commit"
    assert_eq "$(rec role)" follower "the follower's record"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.0.0 "the installed copy stays"

    printf '1.x.0\n' >"$AU_CO/VERSION" && au_commit "$AU_CO" "a version that is not numeric" || return 1
    upd_follower
    assert_rc 0 "VERSION at HEAD is not x.y.z"
    assert_record skipped bad-version "a non-numeric version is a skip"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.0.0 "the installed copy still stays"
}

# ^ invariant how long the post-merge hook of the limit test sleeps; far past the one second au_cut_timeout leaves it, short for a run without a bound
HOOK_HANG_SECONDS=15
HOOK_COMMIT_SUBJECT='made by the post-merge hook'

# ^ coupled lib/autoupdate/autoupdate.sh GSG_UPDATE_QUERY_SECONDS, GSG_UPDATE_STEP_SECONDS and GSG_UPDATE_INSTALL_SECONDS; the record's detail names the limit
QUERY_LIMIT=60 STEP_LIMIT=300 INSTALL_LIMIT=1800
# ^ coupled the calls of one owner run through TIMEOUT_BIN (13 short git calls, 4 long steps, the fetch, the install), each made at most once
MAX_BOUNDED_CALLS=19
# ^ invariant the releases the tag-selection test adds, and the cat-file calls reading all their VERSION files (--batch-check, --batch)
EXTRA_RELEASES=40 TAG_READ_CALLS=2
# ^ coupled autoupdate/autoupdate.sh runs git from at least these many lines (the two runners, the environment query, the fetch); fewer = the search is broken
MIN_GIT_CALL_LINES=4

# ^ external git moves HEAD before it runs post-merge => the timed-out run leaves HEAD at the tag; the next run finds nothing to merge and installs
test_a_merge_that_outlives_its_limit_is_a_failed_run_naming_the_step() {
    local hook
    au_setup_with_release || return 1
    hook="$AU_CO/.git/hooks/post-merge"
    printf '#!/bin/sh\nexec sleep %s\n' "$HOOK_HANG_SECONDS" >"$hook" && chmod 755 "$hook" || return 1
    au_timeout_standin merge cut || return 1
    upd
    assert_rc 1 "a merge held up by a hook past its limit is an error, exit 1"
    assert_record failed "" "the record"
    assert_eq "$(rec detail)" "git merge timed out after $STEP_LIMIT s" "the detail names the step that ran out of time"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.0.0 "nothing was installed"
    assert_eq "$(state_value version)" 1.0.0 "the state still names the old version"
    assert_no_file "$LC_STATE/update.lock" "the lock is released"
    assert_eq "$(au_leftovers)" 0 "no work dir is left"

    rm -f -- "$hook" || return 1
    upd
    assert_rc 0 "the next run, without the hook"
    assert_record updated "" "recovers"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.1.0 "and installs the release"
}

# ^ why --no-verify, not a plain commit; the hook under test is the checkout's post-merge, the installed secret scan is not part of this case
test_an_owner_hook_that_moves_head_fails_the_run_and_nothing_is_installed() {
    local before tagged hook
    au_setup_with_release || return 1
    before="$(au_share_state)" || return 1
    tagged="$(gitx -C "$AU_SRC" rev-parse 'refs/tags/v1.1.0^{commit}')" || return 1
    hook="$AU_CO/.git/hooks/post-merge"
    printf '#!/bin/sh\nexec "%s" commit -q --no-verify --allow-empty -m "%s"\n' "$GIT" "$HOOK_COMMIT_SUBJECT" >"$hook" && chmod 755 "$hook" || return 1
    upd
    assert_rc 1 "a HEAD that is not at the tag after the fast-forward is an error, exit 1"
    assert_record failed "" "the record"
    assert_contains "$(rec detail)" "HEAD is not at v1.1.0 after the fast-forward" "the detail says what was found"
    assert_eq "$(rec from)|$(rec to)" "1.0.0|1.1.0" "from and to"
    assert_eq "$(gitx -C "$AU_CO" log -1 --format=%s)" "$HOOK_COMMIT_SUBJECT" "control: the hook did move HEAD"
    assert_eq "$(gitx -C "$AU_CO" rev-parse 'HEAD^')" "$tagged" "control: by one commit on top of the tag"
    assert_eq "$(au_share_state)" "$before" "the installed copy and the state are unchanged"
    assert_no_file "$LC_STATE/update.lock" "the lock is released"
    assert_eq "$(au_leftovers)" 0 "no work dir is left"
}

# ^ invariant a row = an argument only one git call of an owner run carries, and the git command the record names; the last row alone follows the merge
# ^ why a limit the stand-in lets run out, not a git hanging; real git cannot be made to hang, the kill itself is the merge test's subject
# ^ why the rows on descriptor 3, not on stdin; a command of the loop reading stdin would eat the rows left
test_every_git_call_under_the_lock_that_runs_out_of_time_fails_the_run_naming_it() {
    local word sub
    au_setup_with_release || return 1
    while IFS='|' read -r -u 3 word sub; do
        au_timeout_standin "$word" expire || return 1
        upd
        assert_rc 1 "[$word] a git call past its limit is an error, exit 1"
        assert_record failed "" "[$word] the record"
        assert_eq "$(rec detail)" "git $sub timed out after $QUERY_LIMIT s" "[$word] the detail names the call"
        assert_eq "$(<"$LC_DATA/VERSION")" 1.0.0 "[$word] nothing was installed"
        assert_no_file "$LC_STATE/update.lock" "[$word] the lock is released"
    done 3<<'EOF'
--local-env-vars|rev-parse
--is-shallow-repository|rev-parse
get-url|remote
symbolic-ref|symbolic-ref
--list|tag
%(objectsize)|cat-file
--batch|cat-file
merge-base|merge-base
HEAD^{commit}|rev-parse
EOF
    au_timeout_standin no-such-argument log || return 1
    upd
    assert_rc 0 "control: with no limit running out the same update goes through"
    assert_record updated "" "control: updated"
}

# ^ invariant au_release_stream PREFIX COUNT adds PREFIX.1 to PREFIX.COUNT to main of AU_SRC, a commit with its own VERSION and an annotated tag each
# ^ why one git fast-import, not au_release in a loop; each release is 4 git calls and the test needs only the tags and their VERSION files
# ^ hazard the refs move, the work tree and the index of AU_SRC stay behind; the test publishes refs only
au_release_stream() {
    local prefix="$1" count="$2" i v msg stream="$SANDBOX/au-fast-import" when who='Test User <test@example.invalid>'
    : >"$stream" || return 1
    for ((i = 1; i <= count; i++)); do
        v="$prefix.$i" when="$((1700000000 + i)) +0000"
        msg="release $v"
        {
            printf 'commit refs/heads/main\nmark :%s\ncommitter %s %s\ndata %s\n%s\n' "$i" "$who" "$when" "${#msg}" "$msg"
            if [ "$i" -eq 1 ]; then printf 'from refs/heads/main^0\n'; fi
            printf 'M 100644 inline VERSION\ndata %s\n%s\n\n' "$((${#v} + 1))" "$v"
            printf 'tag v%s\nfrom :%s\ntagger %s %s\ndata %s\nv%s\n' "$v" "$i" "$who" "$when" "$((${#v} + 2))" "$v"
        } >>"$stream" || return 1
    done
    gitx -C "$AU_SRC" fast-import --quiet <"$stream"
}

# ^ invariant au_assert_release_stream PREFIX COUNT = COUNT annotated tags over commits whose VERSION is the tag's version, read with two git calls
au_assert_release_stream() {
    local prefix="$1" count="$2" refs shapes want got i
    refs="$(gitx -C "$AU_SRC" for-each-ref --sort=creatordate --format='%(refname:strip=2) %(objecttype) %(*objecttype) %(*objectname)' "refs/tags/v$prefix.[1-9]*")" || return 1
    shapes="$(awk '{ print $2 " " $3 }' <<<"$refs" | sort -u)"
    assert_eq "$shapes" "tag commit" "every stream tag is annotated and points at a commit"
    assert_eq "$(wc -l <<<"$refs" | tr -d ' ')" "$count" "the stream made $count tags"
    want="$(for ((i = 1; i <= count; i++)); do printf '%s.%s\n' "$prefix" "$i"; done)"
    got="$(awk '{ print $4 ":VERSION" }' <<<"$refs" | gitx -C "$AU_SRC" cat-file --batch | grep -v -e ' blob ' -e '^$')" || return 1
    assert_eq "$got" "$want" "each tagged commit holds the VERSION of its tag, in order"
    assert_eq "$(awk '{ print $1 }' <<<"$refs")" "v${want//$'\n'/$'\nv'}" "and the tags are named for those versions"
}

# ^ invariant EXTRA_RELEASES more releases on origin => a selection reading one tag per git call would show in the count; two cat-file calls read them all
test_tag_selection_costs_a_constant_number_of_git_calls() {
    local calls
    au_setup && au_owner_scene || return 1
    au_release_stream 1.10 "$EXTRA_RELEASES" || return 1
    au_assert_release_stream 1.10 "$EXTRA_RELEASES" || return 1
    au_publish && au_timeout_standin no-such-argument log || return 1
    upd
    assert_rc 0 "update exits 0"
    assert_eq "$(rec result)|$(rec to)" "updated|1.10.$EXTRA_RELEASES" "the highest of the valid releases is chosen"
    calls="$(<"$SANDBOX/au-timeout.log")"
    assert_eq "$(grep -c ' cat-file ' <<<"$calls")" "$TAG_READ_CALLS" "the VERSION files of all candidate tags are read by $TAG_READ_CALLS cat-file calls"
    assert_not_contains "$calls" " show refs/tags/" "and never one tag at a time"
    [ "$(wc -l <<<"$calls")" -le "$MAX_BOUNDED_CALLS" ] || fail "at most $MAX_BOUNDED_CALLS bounded calls in one run, got $(wc -l <<<"$calls")"
}

# ^ invariant a line of lib/autoupdate/autoupdate.sh running git names AU_GIT[@] or GSG_GIT; each must start it through autoupdate_limited or under TIMEOUT_BIN
# ^ invariant a bare git = the word git where a command starts (line start, after ; | & ( { !, after the keywords do or then), indented or not
# ^ why a look at the source, not at a run; a new call on a path no test takes would hold the lock without a bound and no run would show it
test_no_git_call_of_the_update_bypasses_the_bounded_runner() {
    local src="$GSG_PROJECT/lib/autoupdate/autoupdate.sh" calls unbounded bare
    calls="$(grep -E '"\$\{AU_GIT\[@\]\}"|"\$GSG_GIT"' "$src" | grep -v -E '^ *(#|AU_GIT(\+)?=\()')" || fail "no git call found in $src"
    [ "$(wc -l <<<"$calls")" -ge "$MIN_GIT_CALL_LINES" ] || fail "the search finds the git calls of lib/autoupdate/autoupdate.sh, got: $calls"
    unbounded="$(grep -v -E 'autoupdate_limited |"\$TIMEOUT_BIN" -k ' <<<"$calls")" || unbounded=""
    assert_empty "$unbounded" "every git call of lib/autoupdate/autoupdate.sh runs under a limit"
    bare="$(grep -v '^ *#' "$src" | grep -E '(^|[;|&({]|then|do|!)[[:space:]]*git[[:space:]]+')" || bare=""
    assert_empty "$bare" "and no git is run by its bare name"
}

# ^ invariant au_git_probe puts a git first on PATH logging "<starting command>|<arguments>" for each call outside the child install, and runs the real git
# ^ why the parent's command name, not the arguments; a call under autoupdate_limited has timeout as parent, an unbounded one its shell (setsid is skipped)
# ^ why GSG_UPDATE_LOCK_PID unset only, not every call; the child install carries it and runs git calls of its own
au_git_probe() {
    {
        cat <<'EOF'
#!/bin/sh
if [ -z "${GSG_UPDATE_LOCK_PID:-}" ]; then
    p=$PPID
    c=$(ps -o comm= -p "$p" 2>/dev/null); c=${c##*/}
    while [ "$c" = setsid ]; do
        p=$(ps -o ppid= -p "$p" | tr -d ' ')
        c=$(ps -o comm= -p "$p" 2>/dev/null); c=${c##*/}
    done
    printf '%s|%s\n' "$c" "$*" >>"$AU_GIT_LOG"
fi
EOF
        printf 'exec %s "$@"\n' "$GIT"
    } >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git" && : >"$SANDBOX/au-git.log" || return 1
    set_env AU_GIT_LOG="$SANDBOX/au-git.log"
}

# ^ invariant an owner run and a follower run; every git call each makes is the child of timeout, and the log holds enough calls to show the probe saw them
# ^ why besides the source test above, not instead of it; the source test reads one file for the forms it knows, this one sees what ran in any form
test_every_git_call_of_an_update_run_is_started_by_the_bounded_runner() {
    # ^ coupled one installing run makes 17 git calls as owner and 5 as follower (measured); the floors stay below them, a probe missing calls fails
    local run unbounded min_calls=12
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then skip_test "the parent of a call is read with ps -o, which Git for Windows lacks"; fi
    for run in owner follower; do
        if [ "$run" = owner ]; then au_setup_with_release; else au_setup_follower_at_release && min_calls=4; fi || return 1
        au_git_probe || return 1
        if [ "$run" = owner ]; then upd; else upd_follower; fi
        assert_eq "$(rec result)" updated "[$run] the update ran to its end"
        [ "$(wc -l <"$SANDBOX/au-git.log")" -ge "$min_calls" ] || fail "[$run] the probe saw $(wc -l <"$SANDBOX/au-git.log") git calls, expected at least $min_calls"
        unbounded="$(grep -v '^timeout|' "$SANDBOX/au-git.log")" || unbounded=""
        assert_empty "$unbounded" "[$run] every git call of the update is started by timeout"
    done
}

test_a_child_install_that_outlives_its_limit_is_recorded_as_timed_out() {
    au_setup || return 1
    au_broken_installer "exec sleep $HOOK_HANG_SECONDS" && au_release 1.1.0 && au_publish || return 1
    au_timeout_standin install cut || return 1
    upd
    assert_rc 1 "an installer past its limit is an error, exit 1"
    assert_record failed install-failed "the record"
    assert_eq "$(rec detail)" "install timed out after $INSTALL_LIMIT s" "the detail says the install ran out of time, not an exit status"
    assert_eq "$(<"$LC_DATA/VERSION")" 1.0.0 "the old copy stays"
    assert_no_file "$LC_STATE/update.lock" "the lock is released"
}

run_file_tests
