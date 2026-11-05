#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the takeover is RPM package-manager code; the fixtures use the real RPM layout (three of the six files are relative symlinks)
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

GU_CMD="$GSG_PROJECT/bin/git-secret-guard"

test_an_interrupted_takeover_rolls_back_every_file_and_the_dnf_entry() {
    gu_tk_start || return 1
    gu_interrupt_run '.scalar.gsg-new' 1 INT "$GU_CMD" install --take-over-system-git || return 1
    assert_contains "$OUT" "putting everything back" "the rollback ran from the interrupt"
    gu_untouched "interrupted takeover (five of six links swapped)"
}

test_a_killed_takeover_is_finished_by_the_next_run_without_a_doubled_dnf_entry() {
    gu_tk_start || return 1
    gu_interrupt_run 'cp -a' 1 KILL "$GU_CMD" install --take-over-system-git || return 1
    assert_eq "$(grep -c 'git-secret-guard: takeover' "$GU_ROOT/etc/dnf/dnf.conf")" 1 "the killed run left its dnf entry"
    assert_no_file "$GU_TK_DIR/record" "and no record"
    gsg status
    assert_rc 1 "status counts the leftover entry as a problem"
    assert_contains "$OUT" "dnf entry" "and names it"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "the next run finishes the takeover"
    assert_eq "$(grep -c 'git-secret-guard: takeover' "$GU_ROOT/etc/dnf/dnf.conf")" 1 "one marker, not two"
    assert_eq "$(grep -c '^excludepkgs=' "$GU_ROOT/etc/dnf/dnf.conf")" 1 "one excludepkgs line, not a doubled one"
    gu_all_symlinks || fail "the takeover is complete"
    gsg restore-system-git </dev/null
    assert_rc 0 "restore"
    gu_untouched "restore after a killed takeover"
}

test_finishing_the_takeover_after_an_interrupted_restore_keeps_the_saved_originals() {
    local ids
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    ids="$(gu_orig_ids)"
    gu_interrupt_run '.git-shell.gsg-restore' 1 INT "$GU_CMD" restore-system-git || return 1
    gsg status
    assert_rc 1 "status reports the half-restored machine"
    assert_contains "$OUT" "install --take-over-system-git" "and names the advised fix"
    gsg install --take-over-system-git </dev/null
    assert_eq "$(gu_orig_ids)" "$ids" "following the advice did not touch the saved originals (symlinks are not saved as originals)"
    gsg restore-system-git </dev/null
    assert_rc 0 "the final restore"
    gu_untouched "restore after an interrupted restore and a finished takeover"
}

test_a_broken_record_never_lets_install_replace_the_saved_originals() {
    local ids
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    ids="$(gu_orig_ids)"
    printf 'garbage\n' >"$GU_TK_DIR/record"
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "a damaged record with links of ours is refused"
    assert_contains "$ERR" "$GU_TK_DIR/orig" "and the refusal names where the originals are"
    assert_eq "$(gu_orig_ids)" "$ids" "the saved originals are untouched by install"
    gsg restore-system-git </dev/null
    assert_rc 1 "restore refuses a record it cannot read"
    assert_eq "$(gu_orig_ids)" "$ids" "and touches nothing either"
}

test_restore_puts_a_missing_file_back_and_ends_with_the_six_rpm_files() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    rm -f -- "$GU_ROOT/usr/bin/git"
    gsg restore-system-git </dev/null
    assert_rc 0 "restore with /usr/bin/git missing"
    gu_untouched "restore with a missing file"
}

test_restore_keeps_the_backup_when_a_recorded_file_is_neither_ours_nor_the_saved_original() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    rm -f -- "$GU_ROOT/usr/bin/scalar"
    printf '#!/bin/sh\necho someone else\n' >"$GU_ROOT/usr/bin/scalar" && chmod 755 "$GU_ROOT/usr/bin/scalar" || return 1
    printf 'S.5....T.    /usr/bin/scalar\n' >"$SANDBOX/rpm.verify"
    gsg restore-system-git </dev/null
    assert_rc 1 "rpm -V lists the file"
    assert_contains "$ERR" "rpm -V reports it" "and the reason is said"
    assert_file "$GU_TK_DIR/orig/scalar" "the backup of that file stays"
    : >"$SANDBOX/rpm.verify"
    gsg restore-system-git </dev/null
    assert_rc 0 "rpm -V accepts the file"
    assert_no_file "$GU_TK_DIR" "the backup goes once every file checks out"
    assert_contains "$(<"$GU_ROOT/usr/bin/scalar")" "someone else" "the file that is not ours is left alone"
}

test_links_in_place_with_the_dnf_entry_gone_are_finished_by_the_takeover_command() {
    local ids
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    ids="$(gu_orig_ids)"
    printf '%s\n' "$GU_CONF_BEFORE" >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    gsg status
    assert_rc 1 "status counts it as a problem"
    assert_not_contains "$OUT" "no longer scanned" "but does not claim commits are unscanned while git is still our link"
    assert_contains "$OUT" "dnf entry" "and names the dnf entry"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "the advised command finishes it"
    assert_eq "$(grep -c 'git-secret-guard: takeover' "$GU_ROOT/etc/dnf/dnf.conf")" 1 "the entry is back once"
    assert_eq "$(gu_orig_ids)" "$ids" "and the saved originals are the same"
}

test_restore_works_from_the_dnf_marker_alone() {
    gu_tk_start || return 1
    printf '%s\n# git-secret-guard: takeover; original: none\nexcludepkgs=git git-core git-core-doc perl-Git\n' "$GU_CONF_BEFORE" >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    gsg restore-system-git </dev/null
    assert_rc 0 "restore with a marker and no record"
    assert_not_contains "$OUT" "nothing to restore" "it does not say there is nothing to do"
    gu_untouched "restore from the marker alone"
}

test_the_takeover_is_offered_when_bin_comes_before_usr_bin_on_path() {
    gu_tk_start || return 1
    ln -s usr/bin "$GU_ROOT/bin" || return 1
    set_env PATH="$GU_ROOT/usr/local/bin:$GU_ROOT/bin:$SANDBOX/pathbin:$TEST_BASE_PATH"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "install with /bin first on PATH"
    assert_not_contains "$OUT" "nothing to take over" "the file is found under its other spelling"
    gu_all_symlinks || fail "the six files are links of ours"
}

test_an_existing_excludepkgs_line_is_merged_and_restore_gives_the_file_back_byte_for_byte() {
    gu_tk_start || return 1
    printf '[main]\nexcludepkgs=foo bar\nsslverify=1\n' >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    cp -- "$GU_ROOT/etc/dnf/dnf.conf" "$SANDBOX/conf.before" || return 1
    GU_CONF_BEFORE="$(gu_conf)"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover over an existing excludepkgs line"
    assert_contains "$(gu_conf)" "excludepkgs=foo bar git git-core git-core-doc perl-Git" "the names are appended to the line"
    assert_contains "$(gu_conf)" "# git-secret-guard: takeover; original: excludepkgs=foo bar" "and the original line is in the marker"
    gsg restore-system-git </dev/null
    assert_rc 0 "restore"
    assert_eq "$(sha256sum <"$GU_ROOT/etc/dnf/dnf.conf")" "$(sha256sum <"$SANDBOX/conf.before")" "dnf.conf is byte for byte what it was"
    gu_untouched "restore over an existing excludepkgs line"
}

test_a_continued_excludepkgs_line_and_a_conf_without_main_are_refused_before_any_change() {
    local case_name text
    for case_name in continued no-main; do
        gu_tk_start || return 1
        if [ "$case_name" = continued ]; then text=$'[main]\nexcludepkgs=foo\n  bar\n'; else text=$'gpgcheck=1\n'; fi
        printf '%s' "$text" >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
        GU_CONF_BEFORE="$(gu_conf)"
        gsg install --take-over-system-git </dev/null
        assert_rc 1 "refused [$case_name]"
        assert_contains "$ERR" "the system git takeover was refused" "says so [$case_name]"
        gu_untouched "refusal [$case_name]"
    done
}

test_restore_keeps_a_package_the_user_added_and_an_unrelated_line_after_the_marker() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    sed -i 's/^excludepkgs=.*/& mypkg/' "$GU_ROOT/etc/dnf/dnf.conf" || return 1
    gsg restore-system-git </dev/null
    assert_rc 0 "restore"
    assert_contains "$(gu_conf)" "excludepkgs=mypkg" "the package the user added stays on the line"
    assert_not_contains "$(gu_conf)" "git-secret-guard: takeover" "and the marker is gone"
    gu_tk_start || return 1
    printf '[main]\n# git-secret-guard: takeover; original: none\ngpgcheck=0\n' >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    gsg restore-system-git </dev/null
    assert_rc 0 "restore with another line below the marker"
    assert_eq "$(gu_conf)" $'[main]\ngpgcheck=0' "that line is not eaten"
}

test_the_takeover_refuses_a_target_whose_libraries_or_helpers_a_user_could_rewrite() {
    local case_name helper
    for case_name in library writable-helper escaping-link; do
        gu_tk_start || return 1
        helper="$GU_ROOT/usr/local/libexec/git-core/git-helper"
        mkdir -p -- "${helper%/*}" && printf '#!/bin/sh\nexit 0\n' >"$helper" && chmod 755 "$helper" || return 1
        case "$case_name" in
            library) printf '\tlibz.so.1 => /home/someone/lib/libz.so.1 (0x1)\n' >"$SANDBOX/ldd.out" ;;
            writable-helper) chmod 775 "$helper" ;;
            escaping-link) ln -s /etc/hostname "${helper%/*}/git-evil" ;;
        esac
        gsg install --take-over-system-git </dev/null
        assert_rc 1 "unsafe target [$case_name]"
        assert_contains "$ERR" "the system git takeover was refused" "refused [$case_name]"
        gu_untouched "unsafe target [$case_name]"
    done
    gu_tk_start || return 1
    printf '\tlibz.so.1 => /home/someone/lib/libz.so.1 (0x1)\n' >"$SANDBOX/ldd.out"
    gsg install --take-over-system-git </dev/null
    assert_contains "$ERR" "outside the system library directories" "the reason names the library rule"
}

test_dnf_conf_keeps_its_mode_and_the_write_leaves_no_temporary_file() {
    gu_tk_start || return 1
    chmod 600 "$GU_ROOT/etc/dnf/dnf.conf" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    assert_eq "$(stat -c %a "$GU_ROOT/etc/dnf/dnf.conf")" 600 "the mode of dnf.conf is kept"
    assert_no_file "$GU_ROOT/etc/dnf/.dnf.conf.gsg-new" "no temporary file stays"
    gsg restore-system-git </dev/null
    assert_eq "$(stat -c %a "$GU_ROOT/etc/dnf/dnf.conf")" 600 "restore keeps the mode too"
}

test_a_leftover_temporary_link_does_not_block_the_takeover() {
    gu_tk_start || return 1
    ln -s /nonexistent "$GU_ROOT/usr/bin/.git.gsg-new" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover with a leftover .git.gsg-new"
    gu_all_symlinks || fail "the six files are links of ours"
}

test_a_directory_in_the_way_of_a_temporary_link_does_not_stop_the_rollback() {
    gu_tk_start || return 1
    mkdir -- "$GU_ROOT/usr/bin/.scalar.gsg-new" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "the sixth swap cannot create its link"
    assert_contains "$ERR" "every original is back" "the rollback completed"
    assert_not_contains "$ERR" "could not be fully undone" "and does not claim otherwise"
    assert_eq "$(find "$GU_ROOT/usr/bin/.scalar.gsg-new" -mindepth 1 | wc -l)" 0 "nothing was created inside the directory that is in the way"
    rmdir "$GU_ROOT/usr/bin/.scalar.gsg-new" || return 1
    gu_untouched "rollback with a directory in the way"
}

test_untrusted_saved_originals_with_links_of_ours_in_place_are_never_replaced() {
    local ids
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    cp -a --remove-destination -- "$GU_TK_DIR/orig/git" "$GU_ROOT/usr/bin/git" || return 1
    printf '#!/bin/sh\necho tampered\n' >"$GU_TK_DIR/orig/scalar" || return 1
    ids="$(gu_orig_ids)"
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "the saved originals cannot be trusted"
    assert_contains "$ERR" "cannot be trusted" "the refusal says so"
    assert_contains "$ERR" "restore-system-git" "and names the way out"
    assert_eq "$(gu_orig_ids)" "$ids" "no saved original was replaced"
    assert_eq "$(readlink "$GU_ROOT/usr/bin/scalar")" "$GU_ROOT/usr/local/bin/scalar" "and the links of ours are still there"
}

run_file_tests
