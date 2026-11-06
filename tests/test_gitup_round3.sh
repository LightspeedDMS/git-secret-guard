#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the takeover, restore and privileged tool flows are Linux package-manager code
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

test_an_old_git_refusal_leaves_no_global_config_behind() {
    gu_rpm_setup || return 1
    mkdir -p -- "$SANDBOX/fresh" || return 1
    set_env GIT_CONFIG_GLOBAL="$SANDBOX/fresh/gitconfig"
    gsg install </dev/null
    assert_rc 1 "old git, no terminal, explicit config path"
    assert_contains "$ERR" "nothing was changed" "the claim"
    assert_no_file "$SANDBOX/fresh/gitconfig" "is true: no config file appeared"
    gu_rpm_setup || return 1
    lc_real_lookup
    rm -f -- "$LC_HOME/.gitconfig" "$LC_HOME/.config/git/config"
    gsg install </dev/null
    assert_rc 1 "old git, no terminal, git's own lookup"
    assert_contains "$ERR" "nothing was changed" "the claim again"
    assert_no_file "$LC_HOME/.gitconfig" "no ~/.gitconfig appeared"
    assert_no_file "$LC_HOME/.config/git/config" "and no XDG config"
    gu_rpm_setup || return 1
    printf '[user]\n\tname = Keep Me\n' >"$SANDBOX/gitconfig" || return 1
    cp -- "$SANDBOX/gitconfig" "$SANDBOX/gitconfig.before" || return 1
    gsg install </dev/null
    assert_eq "$(<"$SANDBOX/gitconfig")" "$(<"$SANDBOX/gitconfig.before")" "an existing config is byte for byte the same"
}

# ^ invariant the tool paths of the 'as root:' lines of a plan, one per line, sorted and unique
plan_tools() { grep -E '^  as root: ' <<<"$1" | sed -E 's/^  as root: ([^ ]+).*/\1/' | LC_ALL=C sort -u; }
# ^ invariant the tool paths sudo was asked to run, from the stand-in's log
sudo_tools() { gu_log | grep -E '^sudo -- ' | sed -E 's/^sudo -- ([^ ]+).*/\1/' | LC_ALL=C sort -u; }

test_the_source_route_plan_lists_every_privileged_command_with_its_full_path() {
    local line tool
    gu_rpm_setup || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "source route upgrade"
    while IFS= read -r line; do
        assert_contains "$line" "as root: /" "an absolute tool path: ${line:0:70}"
    done < <(grep -E '^  as root: ' <<<"$OUT")
    for tool in mkdir install cp mv; do
        assert_contains "$(plan_tools "$OUT")" "/$tool" "the plan names $tool"
    done
}

test_the_takeover_plan_has_a_heading_and_lists_its_commands_with_full_paths() {
    local line tool
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    assert_contains "$OUT" "system git takeover plan" "the plan has a heading"
    while IFS= read -r line; do
        assert_contains "$line" "as root: /" "an absolute tool path: ${line:0:70}"
    done < <(grep -E '^  as root: ' <<<"$OUT")
    for tool in mkdir cp install mv ln restorecon; do
        assert_contains "$(plan_tools "$OUT")" "/$tool" "the plan names $tool"
    done
}

test_what_the_plan_prints_is_what_sudo_runs() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    check_plan_matches_log "$OUT" "takeover"
    gu_rpm_setup || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "source route"
    check_plan_matches_log "$OUT" "source route"
}

test_a_rolled_back_takeover_runs_only_commands_the_plan_lists() {
    local line word known plan
    gu_tk_start || return 1
    printf 'ln -s' >"$SANDBOX/sudo.failon" && printf '1' >"$SANDBOX/sudo.skip" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "the second link fails and the takeover is rolled back"
    plan="$OUT"
    while IFS= read -r line; do
        if grep -qxF -- "$line" <(plan_all_cmds "$plan"); then continue; fi
        if [[ $line == *"rm -f -- "* ]]; then
            for word in ${line#*" -- "}; do
                known=0
                if grep -F 'rm -f -- ' <(plan_all_cmds "$plan") | grep -qF -- "$word"; then known=1; fi
                assert_eq "$known" "1" "rollback: the leftover file $word is named by an rm -f line of the plan"
            done
            continue
        fi
        fail "rollback: sudo ran a command the plan does not list: $line"
    done < <(sudo_cmds)
}

# ^ invariant a takeover over a newer RPM finds an earlier backup => the annotated mv orig orig.old runs, and it must be a line of the plan
test_the_conditional_plan_line_that_sets_an_earlier_backup_aside_is_listed_and_runs() {
    local n plan
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "first takeover"
    for n in "${GU_TK_NAMES[@]}"; do
        # shellcheck disable=SC2016
        printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.53.0"; exit 0; fi\necho "rpm 2.53 %s"\n' "$n" >"$SANDBOX/new-$n" || return 1
        chmod 755 "$SANDBOX/new-$n" || return 1
        cp -a --remove-destination -- "$SANDBOX/new-$n" "$GU_ROOT/usr/bin/$n" || return 1
    done
    printf '%s\n' "$GU_CONF_BEFORE" >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    rm -f -- "$SANDBOX/gitup.log" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "second takeover over a newer RPM"
    plan="$OUT"
    assert_contains "$(sudo_cmds)" "mv -T -- $GU_TK_DIR/orig $GU_TK_DIR/orig.old" "the earlier backup was set aside"
    assert_contains "$(plan_lines "$plan")" "mv -T -- $GU_TK_DIR/orig $GU_TK_DIR/orig.old  [only when an earlier backup exists]" "and the plan lists that command with its condition"
    check_plan_matches_log "$plan" "takeover over an earlier backup"
}

# ^ invariant a leftover link of a file the failed swap never reaches is removed by the rollback rm -f => the annotated plan line must exist
test_the_conditional_plan_line_that_removes_leftover_files_is_listed_and_runs() {
    local line word known plan ran=0
    gu_tk_start || return 1
    ln -s -- "$GU_ROOT/usr/local/bin/scalar" "$GU_ROOT/usr/bin/.scalar.gsg-new" || return 1
    printf 'ln -s' >"$SANDBOX/sudo.failon" && printf '1' >"$SANDBOX/sudo.skip" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "the second link fails and the takeover is rolled back"
    plan="$OUT"
    assert_contains "$(plan_lines "$plan")" "rm -f -- $GU_ROOT/usr/bin/.<file>.gsg-new" "the plan lists the rm -f line"
    while IFS= read -r line; do
        if [[ $line != *"rm -f -- "* ]]; then continue; fi
        ran=$((ran + 1))
        for word in ${line#*" -- "}; do
            known=0
            if grep -F 'rm -f -- ' <(plan_all_cmds "$plan") | grep -qF -- "$word"; then known=1; fi
            assert_eq "$known" "1" "the leftover $word is named by an rm -f line of the plan"
        done
    done < <(sudo_cmds)
    if [ "$ran" -lt 1 ]; then fail "the rollback ran no rm -f although a leftover link was there"; fi
    assert_no_file "$GU_ROOT/usr/bin/.scalar.gsg-new" "the leftover link is gone"
}

# shellcheck disable=SC2016
test_a_direct_root_run_uses_the_system_path_not_the_callers_path() {
    gu_rpm_setup || return 1
    mkdir -p -- "$SANDBOX/poison" || return 1
    printf '#!/bin/sh\n: >"%s/poison-ran"\n' "$SANDBOX" >"$SANDBOX/poison/touch" && chmod 755 "$SANDBOX/poison/touch" || return 1
    set_env PATH="$SANDBOX/poison:$SANDBOX/pathbin:$TEST_BASE_PATH"
    gu_run 'gitup_paths; gitup_is_root() { return 0; }; gitup_elevate touch "$1"; printf "rc=%s" "$?"' "$SANDBOX/created"
    assert_contains "$OUT" "rc=0" "root run succeeded"
    assert_file "$SANDBOX/created" "through the system path touch"
    assert_no_file "$SANDBOX/poison-ran" "and the caller's PATH was not used"
    gu_run 'gitup_paths; gitup_is_root() { return 0; }; gitup_elevate no-such-tool-here "$1"; printf "rc=%s" "$?"' "$SANDBOX/created2"
    assert_contains "$OUT" "rc=1" "a tool outside the system path is refused"
    assert_contains "$ERR" "no-such-tool-here was not found in the system path" "and the message names it"
}

test_a_stopped_restore_reports_the_state_and_the_next_command_and_leaves_no_temp_dir() {
    local sig
    for sig in INT TERM; do
        gu_tk_start || return 1
        gsg install --take-over-system-git </dev/null
        assert_rc 0 "takeover [$sig]"
        gu_interrupt_run '.git-shell.gsg-restore' 1 "$sig" "$GSG_PROJECT/bin/git-secret-guard" restore-system-git || return 1
        assert_contains "$OUT" "restore-system-git was interrupted" "it says what happened [$sig]"
        assert_contains "$OUT" "links are in place" "it shows the state [$sig]"
        assert_contains "$OUT" "git-secret-guard restore-system-git" "and the next command [$sig]"
        assert_eq "$(ls -A "$SANDBOX/tmp")" "" "no temporary directory is left behind [$sig]"
        gsg restore-system-git </dev/null
        assert_rc 0 "repeating the restore finishes it [$sig]"
        gu_untouched "restore after a stopped restore [$sig]"
    done
}

test_status_after_a_stopped_restore_names_both_ways_out() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    gu_interrupt_run '.git-shell.gsg-restore' 1 INT "$GSG_PROJECT/bin/git-secret-guard" restore-system-git || return 1
    gsg status
    assert_contains "$OUT" "install --take-over-system-git" "status names the way back"
    assert_contains "$OUT" "restore-system-git" "and the way on for someone undoing it"
    assert_contains "$OUT" "no longer scanned" "and still says commits are not scanned"
}

test_an_interrupted_copy_says_what_is_in_the_prefix_and_the_next_step_and_status_and_doctor_show_it() {
    gu_rpm_setup || return 1
    gu_interrupt_run 'cp -dR' 0 INT "$GSG_PROJECT/bin/git-secret-guard" install --upgrade-git || return 1
    assert_contains "$OUT" "partly copied" "the message says files may be in the prefix"
    assert_contains "$OUT" "MANIFEST.partial" "and names the partial manifest"
    assert_contains "$OUT" "install --upgrade-git" "and the next step"
    gsg status
    assert_contains "$OUT" "MANIFEST.partial" "status shows the unfinished copy"
    gsg install --upgrade-git </dev/null
    assert_rc 0 "the rerun finishes the copy"
    gsg status
    assert_not_contains "$OUT" "MANIFEST.partial" "and status stops mentioning it"
    mkdir -p -- "$SANDBOX/roots" "$GU_ROOT/usr/local/share/doc/git-2.99.0-local" || return 1
    printf '%s\n' "$GU_ROOT/usr/local/bin/git" >"$GU_ROOT/usr/local/share/doc/git-2.99.0-local/MANIFEST.partial" || return 1
    gsg status
    assert_contains "$OUT" "MANIFEST.partial" "status shows a later unfinished copy"
    gsg doctor --roots "$SANDBOX/roots"
    assert_rc 0 "doctor does not exit 1 because of an unfinished copy"
    assert_contains "$OUT" "MANIFEST.partial" "doctor shows it"
    assert_contains "$OUT" "WARNING" "as a warning"
    assert_not_contains "$OUT" "PROBLEM" "not as a problem"
}

test_restore_removes_the_empty_state_parent_and_leaves_a_used_one() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    gsg restore-system-git </dev/null
    assert_rc 0 "restore"
    assert_no_file "$GU_ROOT/var/lib/git-secret-guard" "the empty parent directory is gone"
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover again"
    printf 'other\n' >"$GU_ROOT/var/lib/git-secret-guard/other-file" || return 1
    gsg restore-system-git </dev/null
    assert_rc 0 "restore with another file in the parent"
    assert_file "$GU_ROOT/var/lib/git-secret-guard/other-file" "a used parent directory and its file stay"
}

test_the_by_hand_undo_covers_original_none_and_removes_the_backup() {
    local line
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    gsg uninstall --keep-system-git </dev/null
    assert_rc 0 "uninstall --keep-system-git"
    assert_contains "$OUT" "original: none" "the text covers a marker that says original: none"
    assert_contains "$OUT" "rm -rf -- $GU_TK_DIR" "and has the step that removes the backup"
    while IFS= read -r line; do
        line="${line#  sudo }"
        bash -c "$line" || fail "the printed command failed: $line"
    done < <(grep -E '^  sudo (cp|rm) ' <<<"$OUT")
    printf '%s\n' "$GU_CONF_BEFORE" >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    gsg restore-system-git </dev/null
    assert_rc 0 "after the by-hand steps"
    assert_contains "$OUT" "nothing to restore" "status has nothing left to warn about"
    gu_untouched "by-hand undo"
}

test_a_rerun_with_an_active_takeover_says_it_is_active() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "the rerun"
    assert_contains "$OUT" "nothing to take over" "it says there is nothing to do"
    assert_contains "$OUT" "already active" "and why"
}

test_the_make_log_is_kept_when_the_build_fails_and_is_not_named_otherwise() {
    local kept
    gu_rpm_setup || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "a good build"
    assert_not_contains "$OUT$ERR" "make.log" "names no log file that is about to be deleted"
    assert_eq "$(ls -A "$SANDBOX/tmp")" "" "and leaves nothing in TMPDIR"
    gu_rpm_setup || return 1
    : >"$SANDBOX/make.fail" || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 1 "a failing build"
    kept="$(grep -oE "kept in [^ ]+" <<<"$OUT$ERR" | head -n 1)"
    kept="${kept#kept in }"
    assert_contains "$kept" "$SANDBOX/tmp/" "the message names a kept log in TMPDIR"
    assert_file "$kept" "which exists"
    assert_contains "$(<"$kept")" "injected failure" "and holds the make output"
}

test_a_hand_edited_comma_list_of_excluded_packages_is_read_and_removed() {
    local conf
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    conf="$GU_ROOT/etc/dnf/dnf.conf"
    sed '/^excludepkgs=/ s/ /,/g' "$conf" >"$SANDBOX/dnf.conf.comma" && cp -- "$SANDBOX/dnf.conf.comma" "$conf" || return 1
    assert_contains "$(grep '^excludepkgs=' "$conf")" "git,git-core,git-core-doc,perl-Git" "the list uses commas now"
    gsg status
    assert_contains "$OUT" "active (" "status reads the comma list and still says active"
    gsg restore-system-git </dev/null
    assert_rc 0 "restore"
    gu_untouched "restore with a comma list"
}

run_file_tests
