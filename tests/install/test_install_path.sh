#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"

if [ "$TEST_IS_WINDOWS" -eq 1 ]; then FILE_SKIP_REASON="the macOS file flow; the Windows PATH entry has its own adapter tests"; fi

# ^ coupled issue #72 puts the CLI folder on PATH only through the macOS startup file; Linux and every opt-out only print the line to add
ADD_LINE='export PATH="$HOME/.local/bin:$PATH"'
BEGIN_MARK='# begin git-secret-guard PATH'
END_MARK='# end git-secret-guard PATH'

assert_no_cli_record() { assert_eq "$(state_value cli_path)" "" "${1:-the state records no entry of ours}"; }
assert_no_zprofile() { assert_no_file "$LC_HOME/.zprofile" "${1:-no startup file was written}"; }

# ^ invariant the PATH install runs with, the CLI folder spelled as $1 first, as "$LC_BIN" or with one or two trailing slashes
ip_path_with() { set_env PATH="$1:$SANDBOX/pathbin:$TEST_BASE_PATH"; }

# ^ invariant ip_call CODE ARGS... runs CODE in a clean shell with only common.sh, tools.sh and install_path.sh loaded; OUT and RC are the answer
ip_call() {
    local code="$1"
    shift
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'set -u; GSG_ROOT="$1"; shift
for lib in core/common install/tools install/install_path; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
'"$code" _ "$GSG_PROJECT" "$@"
}

# ^ invariant ip_on_path PREFIX PATH FOLDER sets OUT to yes or no = install_path_has_dir FOLDER under PATH, after the shell code PREFIX ("" for none)
ip_on_path() { ip_call "$1"'PATH="$1"; if install_path_has_dir "$2"; then echo yes; else echo no; fi' "$2" "$3"; }

test_the_path_comparison_ignores_trailing_slashes_and_never_matches_a_prefix_or_an_empty_entry() {
    local want="/h/.local/bin" expect
    local -a cases=("/h/.local/bin:yes" "/h/.local/bin/:yes" "/h/.local/bin//:yes" "/x:/h/.local/bin/:/y:yes" "/h/.local:no" "/h/.local/bin/sub:no" "/h/.local/binx:no" ":no" "::/h/.local:no" "/h/.local/bin :no" "H/.local/bin:no")
    for expect in "${cases[@]}"; do
        ip_on_path "" "${expect%:*}" "$want"
        assert_eq "$OUT" "${expect##*:}" "PATH=[${expect%:*}] holds [$want]"
    done
    ip_on_path "" "/" ""
    assert_eq "$OUT" no "an empty folder is never on PATH, even when / is an entry"
    ip_on_path "" "/" "//"
    assert_eq "$OUT" yes "the root is the root however many slashes it has"
}

# ^ external on Windows the folder and each entry go through cygpath -m -l and compare in lower case; a fake cygpath keeps this on every host
test_the_windows_path_comparison_goes_through_cygpath_and_ignores_case() {
    local fake='tools_is_windows() { return 0; }
cygpath() { local p="$4"; if [ "$p" = /bad ]; then return 1; fi; p="${p//\\//}"; case "$p" in /[A-Za-z]/*) p="${p:1:1}:${p:2}" ;; esac; printf "%s\n" "$p"; }
'
    ip_on_path "$fake" "/c/Windows:/C/USERS/Ana/.local/BIN/:/bad" "/c/Users/ana/.local/bin"
    assert_eq "$OUT" yes "another case and another drive-letter spelling are the same folder"
    ip_on_path "$fake" "/c/Windows:/c/Users/ana/.local" "/c/Users/ana/.local/bin"
    assert_eq "$OUT" no "a parent folder is not the folder"
    ip_on_path "$fake" "/bad:/c/Users/ana/.local/bin" "/bad"
    assert_eq "$OUT" no "a folder cygpath cannot name is never matched on a guess"
}

test_install_on_linux_says_where_the_cli_is_and_prints_the_line_to_add_without_changing_a_file() {
    local f
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    assert_contains "$OUT" "git-secret-guard: CLI: $LC_BIN/git-secret-guard" "says where the CLI is"
    assert_contains "$OUT" "PATH: $LC_BIN is not on PATH" "says the folder is not on PATH"
    assert_contains "$OUT" "install changes no file on this platform" "says why nothing was changed"
    assert_contains "$OUT" "add this line to your shell startup file: $ADD_LINE" "gives the exact line"
    assert_no_cli_record
    for f in .profile .bashrc .bash_profile .zprofile .zshrc; do assert_no_file "$LC_HOME/$f" "no startup file $f was written"; done
}

test_a_folder_already_on_path_is_left_alone_whatever_its_trailing_slashes() {
    local spelling
    for spelling in "" / //; do
        lc_mac_begin || return 1
        ip_path_with "$LC_BIN$spelling"
        gsg install
        assert_rc 0 "install with the folder spelled [$LC_BIN$spelling] on PATH"
        assert_contains "$OUT" "PATH: $LC_BIN is already on PATH; nothing was changed" "says nothing is needed"
        assert_not_contains "$OUT" "add this line" "prints no hint"
        assert_no_zprofile
        assert_no_cli_record
    done
}

test_dont_change_path_leaves_the_startup_file_alone_and_prints_the_line() {
    lc_mac_begin || return 1
    gsg install --dont-change-path
    assert_rc 0 "install --dont-change-path"
    assert_contains "$OUT" "--dont-change-path was given" "says why nothing was changed"
    assert_contains "$OUT" "add this line to your shell startup file: $ADD_LINE" "gives the line"
    assert_no_zprofile
    assert_no_cli_record
}

ip_block_text() { printf '%s\n%s\n%s\n' "$BEGIN_MARK" "$ADD_LINE" "$END_MARK"; }
assert_zprofile_is_the_block() { assert_eq "$(<"$LC_HOME/.zprofile")" "$(ip_block_text)" "${1:-the file holds exactly the marked block}"; }

test_a_macos_install_adds_one_marked_block_and_says_so() {
    lc_mac_begin || return 1
    gsg install
    assert_rc 0 "install"
    assert_zprofile_is_the_block
    assert_eq "$(state_value cli_path)" "macos-block 1 0 $LC_HOME/.zprofile" "recorded: created by install, no missing final newline, the file"
    assert_contains "$OUT" "PATH: added a marked block to $LC_HOME/.zprofile" "says what it changed and where"
    assert_contains "$OUT" "a shell opened before this install does not see the change" "says old shells do not see it"
    assert_not_contains "$OUT" "add this line" "no hint when it changed the file"
}

test_a_failed_change_is_reported_with_the_line_and_install_still_succeeds() {
    lc_mac_begin || return 1
    printf 'export A=1\n' >"$LC_HOME/.zprofile" || return 1
    chmod 444 "$LC_HOME/.zprofile" || return 1
    if [ -w "$LC_HOME/.zprofile" ]; then skip_test "this user writes a read-only file"; fi
    gsg install
    assert_rc 0 "a failed PATH change does not fail install"
    assert_contains "$OUT$ERR" "cannot write $LC_HOME/.zprofile" "says what failed"
    assert_contains "$OUT" "add this line to your shell startup file: $ADD_LINE" "still gives the line"
    assert_contains "$(gitx config --global --get-all hook.git-secret-guard.event)" "pre-commit" "the hook stays installed"
    assert_eq "$(<"$LC_HOME/.zprofile")" "export A=1" "the file is as it was"
}

test_a_reinstall_carries_the_record_over_and_never_adds_a_second_block() {
    local rec
    lc_mac_begin || return 1
    gsg install
    assert_rc 0 "first install"
    rec="$(state_value cli_path)"
    assert_contains "$rec" "macos-block 1 0 " "recorded"
    gsg install
    assert_rc 0 "second install, folder still not on PATH"
    assert_zprofile_is_the_block "still one block"
    assert_eq "$(state_value cli_path)" "$rec" "the record is the first install's, not recomputed"
    assert_contains "$OUT" "already has the marked block" "says it is there"
    ip_path_with "$LC_BIN"
    gsg install
    assert_rc 0 "third install, folder on PATH now"
    assert_eq "$(state_value cli_path)" "$rec" "carried over when the folder is on PATH"
    assert_zprofile_is_the_block "and the file is untouched"
    gsg install --dont-change-path
    assert_eq "$(state_value cli_path)" "$rec" "carried over by the opt-out run too"
}

# ^ coupled lib/autoupdate/autoupdate.sh takes the lock for the update run (this test shell plays it) and the child install inherits its pid
ip_take_update_lock() {
    mkdir -p -- "$LC_STATE" && ln -s "$BASHPID" "$LC_STATE/update.lock" || return 1
    set_env GSG_UPDATE_LOCK_PID="$BASHPID"
}
ip_drop_update_lock() { rm -f -- "$LC_STATE/update.lock"; }

# ^ coupled lib/autoupdate/autoupdate.sh lets the child install of update in without the lock; only its verdict, never the bare variable, keeps PATH alone
test_the_child_install_of_update_never_changes_path_but_a_bare_variable_does_not_make_a_child() {
    lc_mac_begin || return 1
    ip_take_update_lock || return 1
    gsg install
    assert_rc 0 "the child install"
    assert_contains "$OUT" "the unattended install of update never changes PATH" "says why"
    assert_contains "$OUT" "add this line to your shell startup file: $ADD_LINE" "prints the line"
    assert_no_zprofile
    assert_no_cli_record
    ip_drop_update_lock
    gsg install
    assert_rc 0 "the variable names a pid, but no lock names it: an ordinary install"
    assert_zprofile_is_the_block "so the file is changed"
}

test_the_child_install_carries_an_earlier_record_over() {
    local rec
    lc_mac_begin || return 1
    gsg install
    assert_rc 0 "an ordinary install first"
    rec="$(state_value cli_path)"
    ip_take_update_lock || return 1
    gsg install
    assert_rc 0 "the child install"
    assert_eq "$(state_value cli_path)" "$rec" "the record of the earlier install is kept"
    assert_zprofile_is_the_block "and so is the block"
    ip_drop_update_lock
}

# ^ invariant uninstall restores the file byte for byte, also a file with no final newline, an empty one, or none at all
test_uninstall_restores_the_startup_file_byte_for_byte() {
    local name content
    for name in with-newline no-final-newline empty-file missing-file user-added-the-same-line; do
        case "$name" in
            with-newline) content=$'export A=1\n' ;;
            no-final-newline) content='export A=1' ;;
            user-added-the-same-line) content="$ADD_LINE"$'\n' ;;
            *) content="" ;;
        esac
        lc_mac_begin || return 1
        if [ "$name" != missing-file ]; then printf '%s' "$content" >"$LC_HOME/.zprofile" || return 1; fi
        gsg install
        assert_rc 0 "install over [$name]"
        assert_contains "$(<"$LC_HOME/.zprofile")" "$BEGIN_MARK" "[$name] the block is there"
        gsg uninstall
        assert_rc 0 "uninstall of [$name]"
        assert_contains "$OUT" "removed the marked PATH block from $LC_HOME/.zprofile" "[$name] says what it removed"
        if [ "$name" = missing-file ]; then
            assert_no_zprofile "[$name] a file install created is removed again"
        else
            cmp -s -- "$LC_HOME/.zprofile" <(printf '%s' "$content") || fail "[$name] the file is not byte for byte what it was"
        fi
    done
}

test_uninstall_keeps_what_the_user_wrote_around_the_block() {
    lc_mac_begin || return 1
    printf 'export A=1\n' >"$LC_HOME/.zprofile" || return 1
    gsg install
    assert_rc 0 "install"
    printf 'export Z=9\n' >>"$LC_HOME/.zprofile" || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_eq "$(<"$LC_HOME/.zprofile")" $'export A=1\nexport Z=9' "only the block is gone"
}

test_uninstall_names_and_leaves_a_block_the_user_changed() {
    local before text nl=$'\n'
    lc_mac_begin || return 1
    gsg install
    assert_rc 0 "install"
    text="$(<"$LC_HOME/.zprofile")" || return 1
    text="${text/"$END_MARK"/export MINE=1${nl}$END_MARK}"
    printf '%s\n' "$text" >"$LC_HOME/.zprofile" || return 1
    before="$(<"$LC_HOME/.zprofile")"
    assert_contains "$nl$before$nl" "${nl}export MINE=1$nl" "test setup, a line of the user's stands inside the block"
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$OUT" "$LC_HOME/.zprofile has the PATH marker but not the block install wrote; left as it is" "names the file and says why"
    assert_eq "$(<"$LC_HOME/.zprofile")" "$before" "the file is untouched"
}

test_uninstall_without_a_record_touches_nothing_even_if_a_marked_block_is_there() {
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "an install that recorded nothing"
    ip_block_text >"$LC_HOME/.zprofile" || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_zprofile_is_the_block "a block we have no record of stays"
    assert_not_contains "$OUT" "PATH block" "and is not mentioned"
}

# ^ invariant ip_win CODE runs CODE on a fake Windows host with both PATH adapters loaded, the CLI folder /c/u/.local/bin off PATH, nothing recorded
ip_win() {
    ip_call 'for l in platform/macpath platform/winpath; do source "$GSG_ROOT/lib/$l.sh" || exit 9; done
tools_is_windows() { return 0; }
cygpath() { printf "%s\n" "${@: -1}"; }
GSG_NAME=git-secret-guard GSG_BIN_DIR=/c/u/.local/bin PATH=/c/other ST_CLI_PATH=""
'"$1"
}

# ^ coupled seam of part 2 is winpath.sh with winpath_plan (REPLY present, absent or unusable, WINPATH_RECORD, WINPATH_WHY), winpath_apply, winpath_remove
test_the_windows_flow_follows_what_winpath_plan_answers() {
    local answer expect
    for answer in absent present unusable; do
        ip_win 'winpath_plan() { REPLY='"$answer"'; WINPATH_RECORD="windows-user-path ;C:/u/bin"; WINPATH_WHY="the adapter says no"; }
install_path_plan; echo "$INSTALL_PATH_ACTION|$INSTALL_PATH_RECORD|$INSTALL_PATH_WHY"'
        case "$answer" in
            absent) expect='add|windows-user-path ;C:/u/bin|' ;;
            present) expect='present||the user Path already holds /c/u/.local/bin' ;;
            *) expect='hint||the adapter says no' ;;
        esac
        assert_eq "$OUT" "$expect" "winpath_plan answers $answer"
    done
    ip_win 'winpath_apply() { return 0; }; INSTALL_PATH_ACTION=add; install_path_apply; echo "$INSTALL_PATH_ACTION|$INSTALL_PATH_DONE"'
    assert_eq "$OUT" "add|added /c/u/.local/bin to the user Path" "winpath_apply worked"
    ip_win 'winpath_apply() { WINPATH_WHY=denied; return 1; }; INSTALL_PATH_ACTION=add; install_path_apply; echo "$INSTALL_PATH_ACTION|$INSTALL_PATH_WHY"'
    assert_eq "$OUT" "failed|denied" "winpath_apply failed: the action failed with the reason, never a failed install"
}

# ^ coupled a change written but not announced to running programs is a success that says what to do; the adapter sets WINPATH_NOBROADCAST
test_a_change_written_but_not_announced_says_to_sign_out_and_in() {
    ip_win 'winpath_apply() { WINPATH_NOBROADCAST=1; return 0; }; INSTALL_PATH_ACTION=add; install_path_apply; install_path_report'
    assert_contains "$OUT" "added /c/u/.local/bin to the user Path" "the change is reported as made"
    assert_contains "$OUT" "could not tell running programs; sign out and in, or start a new session" "with what to do"
    ip_win 'uninstall_say() { echo "say:$1"; }
winpath_remove() { REPLY=removed; WINPATH_NOBROADCAST=1; }
ST_CLI_PATH="windows-user-path ;C:/u/bin"; uninstall_path_entry; echo "rc=$?"'
    assert_contains "$OUT" "say:removed /c/u/.local/bin from the user Path; running programs could not be told, so sign out and in" "uninstall says the same"
}

test_the_windows_hint_and_uninstall_follow_the_adapter() {
    local answer
    ip_win 'INSTALL_PATH_ACTION=hint INSTALL_PATH_WHY="the adapter says no"; install_path_report'
    assert_contains "$OUT" "add /c/u/.local/bin to the Path of your Windows user" "the hint names the folder to add"
    assert_not_contains "$OUT" "shell startup file" "and gives no shell line"
    for answer in removed changed absent; do
        ip_win 'uninstall_say() { echo "say:$1"; }
winpath_remove() { REPLY='"$answer"'; WINPATH_WHY=""; }
ST_CLI_PATH="windows-user-path ;C:/u/bin"; uninstall_path_entry; echo "rc=$?"'
        case "$answer" in
            removed) assert_contains "$OUT" "say:removed /c/u/.local/bin from the user Path" "removed is said" ;;
            changed) assert_contains "$OUT" "the user Path holds /c/u/.local/bin in another spelling than install wrote; left as it is" "a respelled entry is named and left" ;;
            *) assert_eq "$OUT" "rc=0" "nothing to remove is silent" ;;
        esac
    done
    ip_win 'winpath_remove() { echo called; }; ST_CLI_PATH=""; uninstall_path_entry; echo "rc=$?"'
    assert_eq "$OUT" "rc=0" "no record, no call"
}

run_file_tests
