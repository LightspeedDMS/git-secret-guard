#!/usr/bin/env bash
# shellcheck source=tests/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=tests/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lifecycle.sh"
# shellcheck source=tests/gitup.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/gitup.sh"

# ^ external the takeover and the privileged tool lookup are Linux package-manager code; macOS and Windows have their own modules and test files
if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="Linux package manager flows"; fi

test_a_foreign_program_with_a_missing_library_in_usr_local_bin_does_not_block_the_takeover() {
    gu_tk_start || return 1
    mkdir -p -- "$GU_ROOT/usr/local/bin/other-tool" || return 1
    printf '#!/bin/sh\nexit 0\n' >"$GU_ROOT/usr/local/bin/other-tool/libother.so" && chmod 755 "$GU_ROOT/usr/local/bin/other-tool/libother.so" || return 1
    printf '\tlibmissing.so.1 => not found\n' >"$SANDBOX/ldd.out"
    printf 'libother.so' >"$SANDBOX/ldd.only"
    gsg install </dev/null
    assert_contains "$OUT" "install --take-over-system-git" "the offer is printed although an unrelated program has a missing library"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "an unrelated program in the prefix bin directory is not the takeover's business"
    gu_all_symlinks || fail "the six files are links of ours"
    gsg restore-system-git </dev/null
    printf 'git-shell' >"$SANDBOX/ldd.only"
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "a missing library in a program the MANIFEST lists still refuses"
    assert_contains "$ERR" "git-shell has a missing library" "and names it"
}

# shellcheck disable=SC2016
test_root_run_tools_are_looked_up_in_the_sbin_directories_and_restorecon_is_run() {
    gu_tk_start || return 1
    gu_run 'unset GSG_GITUP_BUILD_PATH; gitup_paths; printf "%s|%s" "$GITUP_SYSTEM_PATH" "$GITUP_BUILD_PATH"'
    assert_eq "$OUT" "/usr/bin:/bin:/usr/sbin:/sbin|/usr/bin:/bin" "root-run tools include sbin; the build PATH does not"
    mkdir -p -- "$SANDBOX/sbin" && mv -- "$SANDBOX/pathbin/restorecon" "$SANDBOX/sbin/restorecon" || return 1
    set_env GSG_GITUP_BUILD_PATH="$SANDBOX/pathbin:$SANDBOX/sbin"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover with restorecon found in an sbin directory"
    assert_contains "$(gu_log)" "restorecon" "restorecon ran"
    assert_not_contains "$ERR" "restorecon was not found" "with no warning"
    gsg restore-system-git </dev/null
    rm -f -- "$SANDBOX/sbin/restorecon"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover without restorecon anywhere"
    assert_contains "$ERR" "restorecon was not found" "says so once instead of skipping silently"
}

test_a_partial_manifest_next_to_an_older_finished_one_makes_the_takeover_target_unfinished() {
    gu_tk_start || return 1
    mkdir -p -- "$GU_ROOT/usr/local/share/doc/git-2.57.0-local" || return 1
    printf '%s\n' "$GU_ROOT/usr/local/bin/git" >"$GU_ROOT/usr/local/share/doc/git-2.57.0-local/MANIFEST.partial" || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "a half-copied rebuild"
    assert_contains "$ERR" "unfinished" "is refused as unfinished"
    gu_untouched "refusal over a partial MANIFEST"
}

test_a_timer_refusal_comes_before_the_git_upgrade_offer() {
    local case_name expect
    for case_name in percent-in-state-dir foreign-unit; do
        gu_rpm_setup || return 1
        case "$case_name" in
            percent-in-state-dir)
                set_env XDG_STATE_HOME="$SANDBOX/xdg%state"
                expect="cannot be written into a systemd unit"
                ;;
            foreign-unit)
                mkdir -p -- "$LC_HOME/.config/systemd/user" && printf 'not ours\n' >"$LC_HOME/.config/systemd/user/git-secret-guard-doctor.timer" || return 1
                expect="was not written by git-secret-guard"
                ;;
        esac
        gsg install --upgrade-git --with-timer </dev/null
        assert_rc 1 "refused [$case_name]"
        assert_contains "$ERR" "$expect" "the timer problem is named [$case_name]"
        assert_not_contains "$(gu_log)" "sudo " "no privileged command ran before the refusal [$case_name]"
        assert_not_contains "$(gu_log)" "make " "and nothing was built [$case_name]"
        assert_contains "$ERR" "nothing was changed" "and the claim is true [$case_name]"
    done
}

# shellcheck disable=SC2016
test_the_timer_and_launchd_refusals_use_the_changed_wording() {
    gu_rpm_setup || return 1
    set_env GIT_CONFIG_GLOBAL=rel.cfg
    gu_run 'source "$GSG_ROOT/lib/timer.sh"; source "$GSG_ROOT/lib/launchd.sh"; paths_init || exit 8
        GITUP_CHANGED="git 2.56.0"
        timer_check_config_global
        timer_check_values "/tmp/bad%dir"
        mkdir -p "$GSG_UNIT_DIR" && printf "not ours\n" >"$GSG_UNIT_DIR/$GSG_TIMER_UNIT"
        timer_check_target /tmp
        ctl="$(printf "/tmp/a\001b")"
        launchd_check_values "$ctl"
        mkdir -p "${GSG_AGENT_PLIST%/*}" && printf "not ours\n" >"$GSG_AGENT_PLIST"
        launchd_check_target /tmp
        true'
    assert_not_contains "$ERR" "nothing was changed" "no refusal after a change claims nothing changed"
    assert_eq "$(grep -c 'the only change made was the git upgrade' <<<"$ERR")" "5" "all five say what changed"
}

test_branches_that_each_take_one_reserved_registry_line_merge_without_conflicts() {
    local repo="$SANDBOX/merge" classes=() a b merged
    lc_begin || return 1
    # ^ why the classes still reserved in the library, not a fixed list; a class branch with its module would otherwise edit this line
    mapfile -t classes < <(sed -nE 's/^ +([a-z]+)\) REPLY="" ;;$/\1/p' "$GSG_PROJECT/lib/gitup.sh")
    if [ "${#classes[@]}" -lt 2 ]; then skip_test "fewer than two classes are still reserved, so there is nothing left to merge"; fi
    rm -rf -- "$repo" && mkdir -p -- "$repo/lib" && cp -- "$GSG_PROJECT/lib/gitup.sh" "$repo/lib/gitup.sh" || return 1
    gitx -C "$repo" init -q -b main && gitx -C "$repo" add lib/gitup.sh && gitx -C "$repo" commit -q -m base || return 1
    for a in "${classes[@]}"; do
        gitx -C "$repo" checkout -q -b "mod-$a" main || return 1
        sed -i "s/^\\( *\\)$a) REPLY=[^ ;]* ;;\$/\\1$a) REPLY=${a}mod ;;/" "$repo/lib/gitup.sh" || return 1
        grep -q "^ *$a) REPLY=${a}mod ;;\$" "$repo/lib/gitup.sh" || { fail "no reserved line for $a"; return 1; }
        gitx -C "$repo" commit -q -am "module for $a" || return 1
    done
    for a in "${classes[@]}"; do
        for b in "${classes[@]}"; do
            if [[ $a == "$b" || $a > "$b" ]]; then continue; fi
            gitx -C "$repo" checkout -q -b "pair-$a-$b" "mod-$a" || return 1
            gitx -C "$repo" merge -q --no-edit "mod-$b" >/dev/null 2>&1
            assert_eq "$?" "0" "the branches for $a and $b merge without a conflict"
            gitx -C "$repo" merge --abort >/dev/null 2>&1
        done
    done
    gitx -C "$repo" checkout -q -b all "mod-${classes[0]}" || return 1
    for b in "${classes[@]:1}"; do
        gitx -C "$repo" merge -q --no-edit "mod-$b" >/dev/null 2>&1
        assert_eq "$?" "0" "and the branch for $b joins the others"
    done
    merged="$(<"$repo/lib/gitup.sh")"
    for a in "${classes[@]}"; do assert_contains "$merged" "$a) REPLY=${a}mod" "$a is in the merged registry"; done
}

test_uninstall_stops_for_a_partial_or_broken_takeover() {
    local case_name
    for case_name in partial broken; do
        gu_tk_start || return 1
        gsg install --take-over-system-git </dev/null
        assert_rc 0 "takeover [$case_name]"
        case "$case_name" in
            partial) printf '%s\n' "$GU_CONF_BEFORE" >"$GU_ROOT/etc/dnf/dnf.conf" || return 1 ;;
            broken) printf 'garbage\n' >"$GU_TK_DIR/record" || return 1 ;;
        esac
        gsg uninstall </dev/null
        assert_rc 1 "uninstall stops [$case_name]"
        assert_file "$LC_STATE/state" "and nothing was uninstalled [$case_name]"
        assert_contains "$ERR" "restore-system-git" "the way out is named [$case_name]"
        gsg uninstall --keep-system-git </dev/null
        assert_rc 0 "uninstall --keep-system-git goes on [$case_name]"
        assert_contains "$OUT" "cp -a --remove-destination -- $GU_TK_DIR/orig/git " "and prints the undo by hand [$case_name]"
    done
}

test_a_deleted_excludepkgs_line_is_reported_and_the_entry_comes_back() {
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    grep -v '^excludepkgs' "$GU_ROOT/etc/dnf/dnf.conf" >"$SANDBOX/dnf.conf.cut" && cp -- "$SANDBOX/dnf.conf.cut" "$GU_ROOT/etc/dnf/dnf.conf" || return 1
    assert_contains "$(gu_conf)" "git-secret-guard: takeover" "the marker comment is still there"
    gsg status
    assert_not_contains "$OUT" "active (" "status no longer says active while dnf can overwrite git"
    assert_contains "$OUT" "the dnf entry is gone" "and says the entry is gone"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "the rerun puts the entry back"
    assert_eq "$(grep -c '^excludepkgs=' "$GU_ROOT/etc/dnf/dnf.conf")" "1" "one excludepkgs line"
    assert_eq "$(grep -c 'git-secret-guard: takeover' "$GU_ROOT/etc/dnf/dnf.conf")" "1" "behind one marker"
    assert_contains "$(grep '^excludepkgs=' "$GU_ROOT/etc/dnf/dnf.conf")" "git-core" "naming git-core"
    gsg status
    assert_contains "$OUT" "active (" "and status is active again"
    gsg restore-system-git </dev/null
    assert_rc 0 "restore"
    gu_untouched "restore after the entry came back"
}

test_a_broken_record_prints_the_commands_to_undo_by_hand() {
    local line
    gu_tk_start || return 1
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "takeover"
    printf 'garbage\n' >"$GU_TK_DIR/record" || return 1
    gsg restore-system-git </dev/null
    assert_rc 1 "restore refuses a record it cannot read"
    assert_contains "$ERR" "cp -a --remove-destination -- $GU_TK_DIR/orig/scalar " "and prints the by-hand command for every saved original"
    gsg install --take-over-system-git </dev/null
    assert_rc 1 "install refuses too"
    assert_contains "$ERR" "cp -a --remove-destination -- $GU_TK_DIR/orig/git " "and prints the way out instead of only pointing at restore"
    while IFS= read -r line; do
        line="${line#"${line%%[![:space:]]*}"}"
        bash -c "${line#sudo }" || fail "the printed command failed: $line"
    done < <(grep 'cp -a --remove-destination' <<<"$ERR")
    assert_eq "$(gu_hashes)" "$GU_BEFORE" "running the printed commands brings the six originals back"
    gsg install --take-over-system-git </dev/null
    assert_rc 0 "and the takeover works again"
}

test_the_default_betterleaks_is_the_one_fetch_test_tools_downloads() {
    local home="$SANDBOX/bl-home" cache="$SANDBOX/bl-cache/git-secret-guard-test-tools" got
    [ "$TEST_OS" != Darwin ] || skip_test "the ~/.local/bin fallback is the Linux branch of tests/lib.sh; macOS always uses the cache path"
    lc_begin || return 1
    rm -rf -- "$home" "$SANDBOX/bl-cache" && mkdir -p -- "$home/.local/bin" "$cache" || return 1
    printf '#!/bin/sh\n' >"$cache/betterleaks" && cp -- "$cache/betterleaks" "$home/.local/bin/betterleaks" && chmod 755 "$cache/betterleaks" "$home/.local/bin/betterleaks" || return 1
    # shellcheck disable=SC2016
    got="$(env -i HOME="$home" PATH="$PATH" XDG_CACHE_HOME="$SANDBOX/bl-cache" bash -c 'source "$1/tests/lib.sh" >/dev/null 2>&1; printf %s "$REAL_BETTERLEAKS"' _ "$GSG_PROJECT" </dev/null)"
    assert_eq "$got" "$cache/betterleaks" "the cache wins over ~/.local/bin"
    rm -f -- "$cache/betterleaks"
    # shellcheck disable=SC2016
    got="$(env -i HOME="$home" PATH="$PATH" XDG_CACHE_HOME="$SANDBOX/bl-cache" bash -c 'source "$1/tests/lib.sh" >/dev/null 2>&1; printf %s "$REAL_BETTERLEAKS"' _ "$GSG_PROJECT" </dev/null)"
    assert_eq "$got" "$home/.local/bin/betterleaks" "without a cache copy ~/.local/bin is used"
    # shellcheck disable=SC2016
    got="$(env -i HOME="$home" PATH="$PATH" XDG_CACHE_HOME="$SANDBOX/bl-cache" GSG_TEST_BETTERLEAKS=/explicit/betterleaks bash -c 'source "$1/tests/lib.sh" >/dev/null 2>&1; printf %s "$REAL_BETTERLEAKS"' _ "$GSG_PROJECT" </dev/null)"
    assert_eq "$got" "/explicit/betterleaks" "GSG_TEST_BETTERLEAKS beats both"
}

run_file_tests
