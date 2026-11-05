#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the takeover is RPM package-manager code; macOS and Windows have no system git of this kind
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

gu_no_symlinks() {
    local n
    for n in "${GU_TK_NAMES[@]}"; do
        if [ -L "$GU_ROOT/usr/bin/$n" ] && [[ $(readlink "$GU_ROOT/usr/bin/$n") == "$GU_ROOT/usr/local/"* ]]; then return 1; fi
    done
}

test_taking_over_the_system_git_points_usr_bin_at_usr_local_and_keeps_the_rpm() {
    local n sum
    gu_tk_start || return 1
    sum="$(sha256sum "$GU_ROOT/usr/bin/git")"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "install --take-over-system-git"
    gu_all_symlinks || fail "the six files are not symlinks into /usr/local/bin"
    assert_eq "$("$GU_ROOT/usr/bin/git" --version)" "git version 2.56.0" "/usr/bin/git is the new git"
    for n in "${GU_TK_NAMES[@]}"; do assert_file "$GU_TK_DIR/orig/$n" "the saved original of $n"; done
    assert_eq "$(sha256sum "$GU_TK_DIR/orig/git" | cut -d' ' -f1)" "${sum%% *}" "the saved git is the original, byte for byte"
    assert_contains "$(gu_conf)" "excludepkgs=git git-core git-core-doc perl-Git" "dnf skips every package built from the same source RPM"
    assert_contains "$(gu_conf)" "# git-secret-guard: takeover" "behind a marker comment"
    assert_contains "$(gu_conf)" "tsflags=nodocs" "and the rest of dnf.conf is kept"
    assert_not_contains "$(gu_log)" "rpm -e" "no package was erased"
    assert_not_contains "$(gu_log)" "dnf remove" "and none was removed"
    assert_not_contains "$ERR" "warning: $GU_ROOT/usr/bin/git" "the installer no longer warns about /usr/bin/git"
    assert_contains "$(gu_log)" "restorecon" "labels were restored"
}

test_the_takeover_is_offered_on_any_install_and_declining_changes_nothing() {
    gu_tk_start || return 1
    gsg_pty $'\n' install
    assert_rc 0 "Enter at the takeover prompt"
    assert_contains "$OUT" "Take over $GU_ROOT/usr/bin/git" "the offer names the file"
    assert_contains "$OUT" "[y/N]" "and defaults to No"
    gu_no_symlinks || fail "something in /usr/bin changed"
    assert_eq "$(gu_hashes)" "$GU_BEFORE" "the originals are untouched"
    assert_eq "$(gu_conf)" "$GU_CONF_BEFORE" "no dnf config was written"
    assert_file "$LC_STATE/state" "install continued"
    assert_not_contains "$(gu_log)" "make " "the build of ours was used as it is, with no rebuild"
    gsg install </dev/null
    assert_rc 0 "no terminal and no flag"
    assert_not_contains "$OUT$ERR" "[y/N]" "no prompt"
    assert_contains "$OUT" "--take-over-system-git" "the flag is named"
    assert_eq "$(gu_hashes)" "$GU_BEFORE" "still untouched"
    assert_eq "$(gu_conf)" "$GU_CONF_BEFORE" "still no dnf config"
}

test_answering_yes_at_the_takeover_prompt_takes_over() {
    gu_tk_start || return 1
    gsg_pty $'y\n' install
    assert_rc 0 "yes"
    gu_all_symlinks || fail "the six files are not symlinks"
}

test_the_takeover_states_its_cost_before_asking() {
    gu_tk_start || return 1
    gsg install </dev/null
    assert_contains "$OUT" "dnf stops updating git" "dnf stops"
    assert_contains "$OUT" "pin bump in tools.lock and install --upgrade-git" "updates need a pin bump"
    assert_contains "$OUT" "rpm -V will report these" "rpm -V"
    assert_contains "$OUT" "git-secret-guard restore-system-git" "and how to undo it"
}

test_the_takeover_refuses_an_unsafe_target_and_changes_nothing() {
    local case_name
    for case_name in writable no-manifest homebrew sibling-missing; do
        gu_tk_start || return 1
        case "$case_name" in
            writable) chmod 775 "$GU_ROOT/usr/local/bin/git" ;;
            no-manifest) rm -f -- "$GU_ROOT"/usr/local/share/doc/git-2.56.0-local/MANIFEST ;;
            homebrew) printf '\tlibz.so.1 => /home/linuxbrew/.linuxbrew/lib/libz.so.1 (0x1)\n' >"$SANDBOX/ldd.out" ;;
            sibling-missing) rm -f -- "$GU_ROOT/usr/local/bin/git-shell" ;;
        esac
        gsg install --take-over-system-git </dev/null
        assert_rc 1 "unsafe target [$case_name]"
        assert_contains "$ERR" "the system git takeover was refused" "refused [$case_name]"
        gu_untouched "unsafe target [$case_name]"
    done
    gu_tk_start || return 1
    chmod 775 "$GU_ROOT/usr/local/bin/git"
    gsg install --take-over-system-git </dev/null
    assert_contains "$ERR" "writable by group or others" "the writable reason"
    gu_tk_start || return 1
    rm -f -- "$GU_ROOT"/usr/local/share/doc/git-2.56.0-local/MANIFEST
    gsg install --take-over-system-git </dev/null
    assert_contains "$ERR" "not listed in any MANIFEST of ours" "the MANIFEST reason"
}

test_a_system_git_that_is_already_new_enough_has_nothing_to_take_over() {
    gu_tk_start || return 1
    # shellcheck disable=SC2016
    printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.55.0"; exit 0; fi\n' >"$GU_ROOT/usr/bin/git" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "the package route already gave a new git"
    assert_contains "$OUT" "nothing to take over" "says so"
    gu_no_symlinks || fail "nothing should have changed"
}

test_a_rerun_of_the_takeover_changes_no_file_and_no_config() {
    local rec_before
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "first takeover"
    rec_before="$(cat "$GU_TK_DIR/record")$(gu_hashes)$(gu_conf)"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "second takeover"
    assert_contains "$OUT" "nothing to take over" "says so"
    assert_eq "$(cat "$GU_TK_DIR/record")$(gu_hashes)$(gu_conf)" "$rec_before" "the record, the links and the config are unchanged"
}

test_a_takeover_that_fails_at_any_step_puts_every_original_back() {
    local row text skip
    for row in 'install -m 644|0' 'cp -a|0' 'cp -a|3' 'install -m 644|1' 'ln -s|1' 'mv -T|0' 'mv -T|2' 'mv -T|5' 'verify|0'; do
        text="${row%|*}" skip="${row#*|}"
        gu_tk_start || return 1
        if [ "$text" = verify ]; then
            : >"$SANDBOX/newgit.broken"
        else
            printf '%s' "$text" >"$SANDBOX/sudo.failon"
            printf '%s' "$skip" >"$SANDBOX/sudo.skip"
        fi
        gsg install --take-over-system-git </dev/null
        assert_rc 1 "failure at [$row]"
        assert_contains "$ERR" "the system git takeover failed" "says so for [$row]"
        gu_untouched "failure at [$row]"
    done
}

test_restore_system_git_puts_the_originals_back_without_dnf_or_the_network() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    rm -f -- "$SANDBOX/gitup.log"
    lc_path_without dnf || return 1
    set_env PATH="$GU_ROOT/usr/local/bin:$SANDBOX/pathfarm-dnf"
    gsg restore-system-git </dev/null
    assert_rc 0 "restore-system-git"
    gu_untouched "restore"
    assert_not_contains "$(gu_log)" "dnf " "dnf was never called"
    gsg restore-system-git </dev/null
    assert_rc 0 "a second restore"
    assert_contains "$OUT" "nothing to restore" "says so"
}

test_uninstall_stops_while_a_takeover_is_active_and_keep_system_git_lets_it_finish() {
    local before
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    before="$(gu_hashes)"
    gsg uninstall </dev/null
    assert_rc 1 "uninstall with a takeover active"
    assert_contains "$ERR" "restore-system-git" "names the restore command"
    assert_contains "$ERR" "uninstall --keep-system-git" "and the other choice"
    assert_file "$LC_STATE/state" "nothing was uninstalled"
    gsg uninstall --keep-system-git </dev/null
    assert_rc 0 "uninstall --keep-system-git"
    assert_no_file "$LC_STATE/state" "uninstall finished"
    assert_eq "$(gu_hashes)" "$before" "the takeover stays"
    assert_contains "$OUT" "$GU_TK_DIR/orig" "it prints where the originals are"
    assert_contains "$OUT" "cp" "and how to put them back by hand"
}

test_a_takeover_undone_by_something_else_is_reported_and_applied_again_on_request() {
    local n
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    for n in "${GU_TK_NAMES[@]}"; do cp -a --remove-destination -- "$GU_TK_DIR/orig/$n" "$GU_ROOT/usr/bin/$n" || return 1; done
    printf '%s\n' "$GU_CONF_BEFORE" >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    gsg status
    assert_contains "$OUT" "system git takeover" "status has a line for it"
    assert_contains "$OUT" "no longer scanned" "and says commits through /usr/bin/git are no longer scanned"
    assert_contains "$OUT" "install --take-over-system-git" "with the fix"
    assert_rc 1 "status counts it as a problem"
    mkdir -p "$SANDBOX/no-roots" || return 1
    gsg doctor --roots "$SANDBOX/no-roots"
    assert_contains "$OUT" "PROBLEM  system git takeover" "doctor reports a problem"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "applied again"
    gu_all_symlinks || fail "the takeover is back"
}

test_a_new_rpm_version_over_the_saved_originals_is_said_not_overwritten_silently() {
    local n
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    for n in "${GU_TK_NAMES[@]}"; do
        # shellcheck disable=SC2016
        printf '#!/bin/sh\nif [ "$1" = --version ]; then echo "git version 2.53.0"; exit 0; fi\necho "rpm 2.53 %s"\n' "$n" >"$SANDBOX/new-$n" || return 1
        chmod 755 "$SANDBOX/new-$n" || return 1
        cp -a --remove-destination -- "$SANDBOX/new-$n" "$GU_ROOT/usr/bin/$n" || return 1
    done
    printf '%s\n' "$GU_CONF_BEFORE" >"$GU_ROOT/etc/dnf/dnf.conf" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "applied again over a newer RPM"
    assert_contains "$OUT" "saved originals" "the output says the saved originals differ"
    assert_contains "$OUT" "replaced" "and were replaced"
    assert_contains "$(<"$GU_TK_DIR/orig/git")" "rpm 2.53" "the new RPM file is the saved one now"
}

test_restoring_an_undone_takeover_leaves_the_rpm_files_alone_and_cleans_up() {
    local n
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    for n in "${GU_TK_NAMES[@]}"; do cp -a --remove-destination -- "$GU_TK_DIR/orig/$n" "$GU_ROOT/usr/bin/$n" || return 1; done
    gsg restore-system-git </dev/null
    assert_rc 0 "restore after the RPM put its files back"
    gu_untouched "restore of an undone takeover"
}

test_the_takeover_exists_only_for_classes_whose_module_provides_it() {
    lc_begin && gu_old_git 2.56.0 && gu_os_release 'ID=ubuntu' || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "ubuntu has no takeover"
    assert_contains "$ERR" "--take-over-system-git is not available on a system of class ubuntu" "says why"
    gsg restore-system-git </dev/null
    assert_rc 0 "restore on a system without takeover"
    assert_contains "$OUT" "nothing to restore" "says so"
}

run_file_tests
