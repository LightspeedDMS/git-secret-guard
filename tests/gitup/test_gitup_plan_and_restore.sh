#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup.sh"

# ^ external the takeover, restore and privileged tool flows are Linux package-manager code
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

# ^ invariant the tool paths of the 'as root:' lines of a plan, one per line, sorted and unique
plan_tools() { grep -E '^  as root: ' <<<"$1" | sed -E 's/^  as root: ([^ ]+).*/\1/' | LC_ALL=C sort -u; }
# ^ invariant the tool paths sudo was asked to run, from the stand-in's log
sudo_tools() { gu_log | grep -E '^sudo -- ' | sed -E 's/^sudo -- ([^ ]+).*/\1/' | LC_ALL=C sort -u; }

# ^ invariant assert_plan_format PLAN TOOL... => every as-root line of PLAN starts with an absolute path, and PLAN names each TOOL
assert_plan_format() {
    local plan="$1" line tool tools
    shift
    while IFS= read -r line; do
        assert_contains "$line" "as root: /" "an absolute tool path: ${line:0:70}"
    done < <(grep -E '^  as root: ' <<<"$plan")
    tools="$(plan_tools "$plan")"
    for tool in "$@"; do
        assert_contains "$tools" "/$tool" "the plan names $tool"
    done
}

test_what_the_plan_prints_is_what_sudo_runs() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    check_plan_matches_log "$OUT" "takeover"
    assert_contains "$OUT" "system git takeover plan" "the plan has a heading"
    assert_plan_format "$OUT" mkdir cp install mv ln restorecon
    gu_rpm_setup || return 1
    gsg install --upgrade-git </dev/null
    assert_rc 0 "source route"
    check_plan_matches_log "$OUT" "source route"
    assert_plan_format "$OUT" mkdir install cp mv
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
        if [[ $line != *"rm -f -- "* ]]; then
            if ! grep -qxF -- "$line" <(plan_all_cmds "$plan"); then fail "rollback: sudo ran a command the plan does not list: $line"; fi
            continue
        fi
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
        gsg status
        assert_contains "$OUT" "install --take-over-system-git" "status names the way back [$sig]"
        assert_contains "$OUT" "restore-system-git" "and the way on for someone undoing it [$sig]"
        assert_contains "$OUT" "no longer scanned" "and still says commits are not scanned [$sig]"
        gsg restore-system-git </dev/null
        assert_rc 0 "repeating the restore finishes it [$sig]"
        gu_untouched "restore after a stopped restore [$sig]"
    done
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
