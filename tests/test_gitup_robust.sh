#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the source build is Linux package-manager code; macOS and Windows have their own modules and test files
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

GU_CMD="$GSG_PROJECT/bin/git-secret-guard"

test_a_copy_that_stops_leaves_a_partial_manifest_and_the_next_run_finishes_it() {
    local doc
    gu_rpm_setup || return 1
    doc="$GU_ROOT/usr/local/share/doc/git-2.56.0-local"
    printf 'cp -dR' >"$SANDBOX/sudo.failon"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the copy fails"
    assert_file "$doc/MANIFEST.partial" "an unfinished copy leaves a partial MANIFEST"
    assert_no_file "$doc/MANIFEST" "and no finished one"
    assert_contains "$ERR" "MANIFEST.partial" "the refusal names it"
    mkdir -p -- "$GU_ROOT/usr/local/bin" || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.56.0"; exit 0; fi\nexec %s "$@"\n' "$GIT" >"$GU_ROOT/usr/local/bin/git" || return 1
    chmod 755 "$GU_ROOT/usr/local/bin/git" || return 1
    rm -f -- "$SANDBOX/gitup.log"
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the rerun finishes the copy although git itself already landed"
    assert_contains "$(gu_log)" "cp -dR" "it copied again"
    assert_file "$doc/MANIFEST" "the MANIFEST is finished"
    assert_no_file "$doc/MANIFEST.partial" "and the partial one is gone"
    assert_file "$GU_ROOT/usr/local/libexec/git-core/git-stand-in-helper" "the rest of the tree landed too"
}

# shellcheck disable=SC2016
test_a_restrictive_umask_changes_no_mode_of_an_existing_directory() {
    local d
    gu_rpm_setup || return 1
    mkdir -p -- "$GU_ROOT/usr/local/share/man/man1" || return 1
    chmod 755 "$GU_ROOT/usr/local/share" "$GU_ROOT/usr/local/share/man" "$GU_ROOT/usr/local/share/man/man1" || return 1
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'umask 027; exec "$0" install --upgrade-git' "$GU_CMD" </dev/null
    assert_rc 0 "install under umask 027"
    for d in share/man share/man/man1 share/doc/git-2.56.0-local libexec/git-core; do
        assert_eq "$(stat -c %a "$GU_ROOT/usr/local/$d")" 755 "mode of $d"
    done
    gu_tk_start || return 1
    run_cap env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'umask 027; exec "$0" install --take-over-system-git' "$GU_CMD" </dev/null
    assert_rc 0 "takeover under umask 027"
    assert_eq "$(stat -c %a "$GU_TK_DIR")" 755 "the backup directory is readable"
    assert_eq "$(stat -c %a "$GU_TK_DIR/orig")" 755 "and so is orig"
    assert_eq "$(stat -c %a "$GU_TK_DIR/record")" 644 "and the record, so the user sees the takeover"
}

test_a_failed_removal_of_obsolete_files_after_a_good_copy_still_says_git_was_installed() {
    gu_rpm_setup || return 1
    gu_old_build 2.55.0 || return 1
    printf 'rm -f' >"$SANDBOX/sudo.failon"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "the removal fails"
    assert_contains "$ERR" "git 2.56.0 was installed into" "the refusal says the new git is in place"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "and it is"
}

test_an_interrupt_during_the_build_says_the_build_dependencies_were_installed() {
    local pid
    gu_rpm_setup || return 1
    : >"$SANDBOX/make.hang"
    (setsid env --default-signal=INT env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GU_CMD" install --upgrade-git >"$SANDBOX/int.out" 2>&1 </dev/null & echo $! >"$SANDBOX/int.pid")
    pid="$(<"$SANDBOX/int.pid")"
    if [ -z "$pid" ]; then fail "no pid for the started command"; return 1; fi
    gu_poll "$GU_STALL_WAIT_TICKS" test -e "$SANDBOX/make.started" || { kill -KILL -- "-$pid" 2>/dev/null; fail "the build never started"; return 1; }
    kill -INT -- "-$pid" 2>/dev/null
    gu_poll "$GU_EXIT_WAIT_TICKS" gu_pid_gone "$pid" || { kill -KILL -- "-$pid" 2>/dev/null; fail "install did not end after SIGINT"; return 1; }
    OUT="$(<"$SANDBOX/int.out")"
    assert_contains "$OUT" "interrupted" "the interruption is reported"
    assert_contains "$OUT" "build dependencies were installed" "with what the upgrade changed"
}

test_a_rebuild_under_an_active_takeover_is_refused_before_anything_is_copied() {
    GU_TK_PIN=2.57.0 gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover (the build is older than the pin, which only a rebuild would fix)"
    rm -f -- "$SANDBOX/gitup.log"
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a rebuild under an active takeover is refused"
    assert_contains "$ERR" "restore-system-git" "the way out is named"
    assert_not_contains "$(gu_log)" "cp -dR" "nothing was copied"
    assert_not_contains "$(gu_log)" "dnf install" "and no dependency was installed"
    gu_all_symlinks || fail "the takeover is still in place"
    gsg install </dev/null
    assert_rc 0 "without the flag the install goes on"
    assert_contains "$ERR" "restore-system-git" "and still says why the rebuild is not offered"
}

test_a_relative_tmpdir_is_refused_instead_of_hanging() {
    gu_rpm_setup || return 1
    set_env TMPDIR=relative-tmp
    mkdir -p -- "$SANDBOX/cwd/relative-tmp" || return 1
    pushd "$SANDBOX/cwd" >/dev/null || return 1
    run_cap timeout 60 env -i "${LC_ENV[@]}" "${EXTRA_ENV[@]}" "$GU_CMD" install --upgrade-git </dev/null
    popd >/dev/null || return 1
    assert_rc 1 "install refuses (a hang would end at rc 124)"
    assert_contains "$ERR" "TMPDIR must be an absolute path" "and says why"
}

test_the_checks_that_can_refuse_run_before_the_git_upgrade_offer() {
    local case_name
    for case_name in malformed-state read-only-config; do
        gu_rpm_setup || return 1
        case "$case_name" in
            malformed-state)
                mkdir -p -- "$LC_STATE" && printf 'garbage\n' >"$LC_STATE/state" || return 1
                ;;
            read-only-config)
                mkdir -p -- "$SANDBOX/ro" && : >"$SANDBOX/ro/gitconfig" && chmod 555 "$SANDBOX/ro" || return 1
                set_env GIT_CONFIG_GLOBAL="$SANDBOX/ro/gitconfig"
                ;;
        esac
        gsg install --upgrade-git </dev/null
        chmod 755 "$SANDBOX/ro" 2>/dev/null
        assert_rc 1 "refused [$case_name]"
        assert_not_contains "$(gu_log)" "sudo " "no privileged command ran [$case_name]"
        assert_not_contains "$(gu_log)" "make " "and nothing was built [$case_name]"
    done
}

test_a_refusal_after_the_upgrade_says_what_the_upgrade_changed() {
    gu_rpm_setup || return 1
    rm -f -- "$SANDBOX/pathbin/git"
    lc_path_without git || return 1
    set_env PATH="$GU_ROOT/usr/local/bin:$SANDBOX/pathbin:$SANDBOX/pathfarm-git"
    printf '2.55.0\n' >"$SANDBOX/dnf.candidate"
    printf '2.55.0' >"$SANDBOX/dnf.upgrade_to"
    mkdir -p -- "$LC_STATE" && printf 'garbage\n' >"$LC_STATE/state" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a malformed state file is still refused when git was missing"
    assert_contains "$(gu_log)" "dnf install -y git-core" "the missing git was installed first"
    assert_contains "$ERR" "the only change made was the git upgrade of this run" "and the refusal says so"
}

test_an_old_git_without_show_scope_reaches_the_upgrade_offer() {
    gu_rpm_setup 2.25.1 || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.25.1"; exit 0; fi\ncase " $* " in *" --show-scope "*) echo "error: unknown option show-scope" >&2; exit 129 ;; esac\nexec %s "$@"\n' "$GIT" >"$SANDBOX/pathbin/git" || return 1
    chmod 755 "$SANDBOX/pathbin/git" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the upgrade runs, and the checks that need --show-scope run after it"
    assert_not_contains "$ERR" "cannot read the global git config" "no early failure"
    assert_eq "$("$GU_ROOT/usr/local/bin/git" --version)" "git version 2.56.0" "git was built"
}

run_file_tests
