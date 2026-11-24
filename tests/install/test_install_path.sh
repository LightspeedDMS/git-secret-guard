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

# ^ invariant ip_call CODE ARGS... runs CODE in a clean shell with only common.sh, state.sh, tools.sh and install_path.sh loaded; OUT and RC are the answer
ip_call() {
    local code="$1"
    shift
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" bash -c 'set -u; GSG_ROOT="$1"; shift
for lib in core/common core/state install/tools install/install_path; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
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

# ^ external on Windows the folder and PATH go through cygpath -m -l (-p for the list), compared in lower case; a fake cygpath keeps this on every host
# ^ invariant two cygpath starts per answer, one for the folder and one for the list, whatever the length of PATH; the fake logs its arguments to @LOG@
test_the_windows_path_comparison_goes_through_one_cygpath_list_call_and_ignores_case() {
    local log="$SANDBOX/cygpath.log" fake
    fake='tools_is_windows() { return 0; }
cygpath() {
    local last="${*: -1}" e out=""
    local -a items=("$last")
    echo "$*" >>@LOG@
    if [[ " $* " == *" -p "* ]]; then IFS=: read -ra items <<<"$last"; fi
    for e in "${items[@]}"; do
        if [ "$e" = /bad ]; then return 1; fi
        e="${e//\\//}"
        case "$e" in /[A-Za-z]/*) e="${e:1:1}:${e:2}" ;; esac
        out+="$e;"
    done
    printf "%s\n" "${out%;}"
}
'
    fake="${fake//@LOG@/$log}"
    : >"$log" || return 1
    ip_on_path "$fake" "/c/Windows:/C/USERS/Ana/.local/BIN/:/d/x" "/c/Users/ana/.local/bin"
    assert_eq "$OUT" yes "another case, another drive-letter spelling and a trailing slash are the same folder"
    assert_eq "$(wc -l <"$log" | tr -d ' ')" 2 "one cygpath start for the folder and one for the whole PATH"
    assert_contains "$(<"$log")" "-m -l -p -- /c/Windows:/C/USERS/Ana/.local/BIN/:/d/x" "the PATH goes in as one list"
    ip_on_path "$fake" "/c/Windows:/c/Users/ana/.local" "/c/Users/ana/.local/bin"
    assert_eq "$OUT" no "a parent folder is not the folder"
    ip_on_path "$fake" "/bad:/c/Users/ana/.local/bin" "/bad"
    assert_eq "$OUT" no "a folder cygpath cannot name is never matched on a guess"
    ip_on_path "$fake" "/c/Windows:/c/Users/ana/.local/bin:/bad" "/c/Users/ana/.local/bin"
    assert_eq "$OUT" no "a PATH cygpath cannot convert matches nothing, not even an entry before the bad one"
    : >"$log" || return 1
    ip_on_path "$fake" "::/c/Windows::/C/USERS/Ana/.local/BIN/:" "/c/Users/ana/.local/bin"
    assert_eq "$OUT" yes "empty entries (leading, middle, trailing) lose no other entry"
    assert_eq "$(sed -n 2p "$log")" "-m -l -p -- /c/Windows:/C/USERS/Ana/.local/BIN/" "cygpath is never given an empty entry, whatever it would make of one"
    : >"$log" || return 1
    ip_on_path "$fake" ":::" "/c/Users/ana/.local/bin"
    assert_eq "$OUT" no "a PATH of separators only matches nothing"
    assert_eq "$(wc -l <"$log" | tr -d ' ')" 1 "and starts no list call"
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

# ^ invariant ip_readonly_zprofile leaves ~/.zprofile as one user line, read-only; the test is skipped for a user who writes read-only files
ip_readonly_zprofile() {
    printf 'export A=1\n' >"$LC_HOME/.zprofile" || return 1
    chmod 444 "$LC_HOME/.zprofile" || return 1
    if [ -w "$LC_HOME/.zprofile" ]; then skip_test "this user writes a read-only file"; fi
}

# ^ invariant the record goes into the state right before the change and is taken back when nothing was written; a stale one could cut a later user line
test_a_failed_change_is_reported_with_the_line_leaves_no_record_and_install_still_succeeds() {
    lc_mac_begin || return 1
    ip_readonly_zprofile || return 1
    gsg install
    assert_rc 0 "a failed PATH change does not fail install"
    assert_contains "$OUT$ERR" "cannot write $LC_HOME/.zprofile" "says what failed"
    assert_contains "$OUT" "add this line to your shell startup file: $ADD_LINE" "still gives the line"
    assert_contains "$(gitx config --global --get-all hook.git-secret-guard.event)" "pre-commit" "the hook stays installed"
    assert_eq "$(<"$LC_HOME/.zprofile")" "export A=1" "the file is as it was"
    assert_no_cli_record "the state keeps no record of a change that was not made"
    chmod 644 "$LC_HOME/.zprofile" || return 1
    printf '%s\n' "$ADD_LINE" >>"$LC_HOME/.zprofile" || return 1
    gsg uninstall
    assert_rc 0 "uninstall"
    assert_contains "$(<"$LC_HOME/.zprofile")" "$ADD_LINE" "the line the user added afterwards stays"
}

test_a_failed_change_keeps_the_record_an_earlier_install_made() {
    local rec
    lc_mac_begin || return 1
    gsg install
    assert_rc 0 "first install"
    rec="$(state_value cli_path)"
    rm -f -- "$LC_HOME/.zprofile" || return 1
    ip_readonly_zprofile || return 1
    gsg install
    assert_rc 0 "second install, the block gone and the file read-only"
    assert_contains "$OUT$ERR" "cannot write $LC_HOME/.zprofile" "the failure is printed"
    assert_eq "$(state_value cli_path)" "$rec" "the first install's record is as it was, not the failed run's"
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

# ^ invariant one record slot; an earlier record stays until its block is gone or can be checked, whatever the login shell is
test_an_earlier_record_is_kept_and_nothing_is_added_while_its_block_may_still_be_there() {
    local variant rec why before p limit=1048576 other="has the PATH marker of ours in a form install did not write"
    for variant in nul-byte over-the-limit crlf-marker trailing-space-marker; do
        lc_mac_begin || return 1
        gsg install
        assert_rc 0 "[$variant] first install, the login shell is zsh"
        rec="$(state_value cli_path)"
        p="$LC_HOME/.zprofile"
        case "$variant" in
            nul-byte) why="holds a NUL byte" && printf 'a\0b\n' >"$p" ;;
            over-the-limit) why="is larger than $limit bytes" && head -c "$((limit + 1))" /dev/zero | tr '\0' a >"$p" ;;
            crlf-marker) why="$other" && printf '%s\r\n%s\r\n%s\r\n' "$BEGIN_MARK" "$ADD_LINE" "$END_MARK" >"$p" ;;
            *) why="$other" && printf '%s \n%s\n%s\n' "$BEGIN_MARK" "$ADD_LINE" "$END_MARK" >"$p" ;;
        esac || return 1
        before="$(cksum <"$p")"
        printf '/bin/bash\n' >"$SANDBOX/dscl.shell" || return 1
        gsg install
        assert_rc 0 "[$variant] second install, the login shell is bash now"
        assert_contains "$OUT" "$why" "[$variant] says why"
        assert_contains "$OUT" "the state records a block of ours in $p; install left it alone and kept the record" "[$variant] says the earlier block is the reason"
        assert_contains "$OUT" "add this line to your shell startup file: $ADD_LINE" "[$variant] prints the line to add"
        assert_no_file "$LC_HOME/.bash_profile" "[$variant] nothing was written for bash"
        assert_eq "$(state_value cli_path)" "$rec" "[$variant] the earlier record is kept"
        assert_eq "$(cksum <"$p")" "$before" "[$variant] the recorded file is untouched"
    done
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

# ^ invariant ip_mac CODE ARGS... runs CODE with macpath.sh loaded and uninstall_say printing "say:TEXT"; $1 is the home directory of the probe, set as HOME
ip_mac() {
    local code="$1"
    shift
    ip_call 'source "$GSG_ROOT/lib/platform/macpath.sh" || exit 9
GSG_NAME=git-secret-guard HOME="$1"
uninstall_say() { echo "say:$1"; }
'"$code" "$@"
}

test_uninstall_names_and_leaves_a_block_whose_marker_line_is_not_the_one_install_wrote() {
    local variant h="$SANDBOX/iphome" before
    for variant in crlf trailing-space; do
        rm -rf -- "${h:?}" && mkdir -p -- "$h" || return 1
        case "$variant" in
            crlf) printf '%s\r\n%s\r\n%s\r\n' "$BEGIN_MARK" "$ADD_LINE" "$END_MARK" >"$h/.zprofile" ;;
            *) printf '%s \n%s\n%s\n' "$BEGIN_MARK" "$ADD_LINE" "$END_MARK" >"$h/.zprofile" ;;
        esac || return 1
        before="$(cksum <"$h/.zprofile")"
        ip_mac 'ST_CLI_PATH="macos-block 0 0 $HOME/.zprofile"; uninstall_path_entry; echo "rc=$?"' "$h"
        assert_contains "$OUT" "rc=0" "[$variant] uninstall goes on"
        assert_contains "$OUT" "$h/.zprofile has the PATH marker but not the block install wrote; left as it is" "[$variant] names the file and says why"
        assert_eq "$(cksum <"$h/.zprofile")" "$before" "[$variant] the file is untouched"
    done
}

# ^ invariant a record names ~/.zprofile or ~/.bash_profile of this account only; a hand-edited one never reaches another file and a rerun is not blocked
test_uninstall_touches_only_the_two_startup_files_a_record_may_name() {
    local h="$SANDBOX/iphome" other before
    other="$h/other-file"
    rm -rf -- "${h:?}" && mkdir -p -- "$h" || return 1
    ip_block_text >"$other" || return 1
    before="$(cksum <"$other")"
    ip_mac 'ST_CLI_PATH="macos-block 1 0 $2"; uninstall_path_entry; echo "rc=$?"' "$h" "$other"
    assert_contains "$OUT" "rc=0" "uninstall goes on"
    assert_contains "$OUT" "the record names $other, which is not ~/.zprofile or ~/.bash_profile; left as it is" "another file is named and refused"
    assert_eq "$(cksum <"$other")" "$before" "the file is untouched, though the record says install created it"
    ip_block_text >"$h/.bash_profile" || return 1
    ip_mac 'ST_CLI_PATH="macos-block 1 0 $HOME/.bash_profile"; uninstall_path_entry; echo "rc=$?"' "$h"
    assert_contains "$OUT" "say:removed the marked PATH block from $h/.bash_profile and the file itself, which install created" "the .bash_profile of the account is accepted"
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
install_path_plan; echo "$INSTALL_PATH_ACTION|$INSTALL_PATH_NEWREC|$INSTALL_PATH_RECORD|$INSTALL_PATH_WHY"'
        case "$answer" in
            absent) expect='add|windows-user-path ;C:/u/bin||' ;;
            present) expect='present|||the user Path already holds /c/u/.local/bin' ;;
            *) expect='hint|||the adapter says no' ;;
        esac
        assert_eq "$OUT" "$expect" "winpath_plan answers $answer"
    done
    ip_win 'install_write_state() { return 0; }; winpath_apply() { return 0; }; INSTALL_PATH_ACTION=add; install_path_apply; echo "$INSTALL_PATH_ACTION|$INSTALL_PATH_DONE"'
    assert_eq "$OUT" "add|added /c/u/.local/bin to the user Path" "winpath_apply worked"
}

# ^ invariant one record slot; a record for another folder stays and the plan is a hint, the same folder in any case or form is added again
test_the_windows_flow_keeps_an_earlier_record_for_another_folder_and_adds_nothing() {
    local row old expect rec why
    for row in 'windows-user-path ;C:\old\bin|hint|windows-user-path ;C:\old\bin|the state records an entry for another folder, C:\old\bin, which git-secret-guard uninstall removes' \
        'windows-user-path C:\NEW\BIN|add||' 'windows-user-path created C:\new\bin|add||' '|add||'; do
        IFS='|' read -r old expect rec why <<<"$row"
        ip_win 'winpath_plan() { REPLY=absent; WINPATH_RECORD='"'windows-user-path ;C:\\new\\bin'"'; if [ "$1" = '"'C:\\old\\bin'"' ]; then REPLY=present; fi; }
ST_CLI_PATH='"${old@Q}"'; install_path_plan; echo "$INSTALL_PATH_ACTION|$INSTALL_PATH_RECORD|$INSTALL_PATH_WHY"'
        if [ "$expect" = hint ]; then
            assert_eq "$OUT" "hint|$rec|$why; install left the user Path alone" "[$old] a hint, the earlier record stays"
        else
            assert_eq "$OUT" "add|$old|" "[$old] the same folder is added again"
        fi
    done
}

# ^ invariant the hint for a record of another folder lasts as long as the entry may be there; the plan asks the adapter about the recorded folder
# ^ invariant absent = the user took the old entry out by hand and the plan adds the current folder; present or unusable keep hint and record
test_the_windows_hint_goes_when_the_recorded_entry_is_gone_but_stays_when_present_or_unusable() {
    local answer
    for answer in absent present unusable; do
        ip_win 'winpath_plan() {
    if [ "$1" = /c/u/.local/bin ]; then REPLY=absent WINPATH_RECORD="windows-user-path ;C:\new\bin" WINPATH_WHY="for the new folder"
    elif [ "$1" = "C:\old\bin" ]; then REPLY='"$answer"' WINPATH_RECORD="windows-user-path ;C:\stale\bin" WINPATH_WHY="the adapter cannot read it"
    else REPLY=unusable; fi
}
ST_CLI_PATH="windows-user-path ;C:\old\bin"; install_path_plan; echo "$INSTALL_PATH_ACTION|$INSTALL_PATH_NEWREC|$INSTALL_PATH_RECORD|$INSTALL_PATH_WHY"'
        if [ "$answer" = absent ]; then
            assert_eq "$OUT" 'add|windows-user-path ;C:\new\bin|windows-user-path ;C:\old\bin|' "[$answer] the stale record is replaced by the new folder's"
        else
            assert_contains "$OUT" 'hint||windows-user-path ;C:\old\bin|' "[$answer] the hint and the record stay"
            assert_contains "$OUT" 'C:\old\bin,' "[$answer] the hint names the recorded folder"
        fi
    done
}

# ^ coupled a change written and not announced to running programs is a success with advice on what to do; the adapter sets WINPATH_NOBROADCAST
test_a_change_written_but_not_announced_says_to_sign_out_and_in() {
    ip_win 'install_write_state() { return 0; }; winpath_apply() { WINPATH_NOBROADCAST=1; return 0; }; INSTALL_PATH_ACTION=add; install_path_apply; install_path_report'
    assert_contains "$OUT" "added /c/u/.local/bin to the user Path" "the change is reported as made"
    assert_contains "$OUT" "could not tell running programs; sign out and in, or start a new session" "with what to do"
    ip_win 'uninstall_say() { echo "say:$1"; }
winpath_remove() { REPLY=removed; WINPATH_NOBROADCAST=1; }
ST_CLI_PATH="windows-user-path ;C:\u\bin"; uninstall_path_entry; echo "rc=$?"'
    assert_contains "$OUT" 'say:removed C:\u\bin from the user Path; running programs could not be told, so sign out and in' "uninstall says the same, naming the recorded folder"
}

# ^ coupled the user Path holds the folder, this shell lacks it => a shell open before the entry was added needs the same advice as after a change
test_the_windows_flow_tells_a_shell_opened_before_about_a_folder_the_user_path_already_holds() {
    ip_win 'winpath_plan() { REPLY=present; }; install_path_plan; install_path_report'
    assert_contains "$OUT" "PATH: the user Path already holds /c/u/.local/bin; nothing was changed" "says nothing was changed"
    assert_contains "$OUT" "PATH: a shell opened before this install does not see the change; open a new one" "and that a shell opened before does not see it"
}

test_the_windows_hint_and_uninstall_follow_the_adapter() {
    local answer
    ip_win 'INSTALL_PATH_ACTION=hint INSTALL_PATH_WHY="the adapter says no"; install_path_report'
    assert_contains "$OUT" "add /c/u/.local/bin to the Path of your Windows user" "the hint names the folder to add"
    assert_not_contains "$OUT" "shell startup file" "and gives no shell line"
    for answer in removed changed absent; do
        ip_win 'uninstall_say() { echo "say:$1"; }
winpath_remove() { REPLY='"$answer"'; WINPATH_WHY=""; }
ST_CLI_PATH="windows-user-path ;C:\Users\old\.local\bin"; uninstall_path_entry; echo "rc=$?"'
        case "$answer" in
            removed) assert_contains "$OUT" 'say:removed C:\Users\old\.local\bin from the user Path' "removed names the folder of the record, not the current install folder" ;;
            changed) assert_contains "$OUT" 'the user Path holds C:\Users\old\.local\bin in another spelling than install wrote; left as it is' "a respelled entry is named by the recorded folder and left" ;;
            *) assert_eq "$OUT" "rc=0" "nothing to remove is silent" ;;
        esac
    done
    ip_win 'winpath_remove() { echo called; }; ST_CLI_PATH=""; uninstall_path_entry; echo "rc=$?"'
    assert_eq "$OUT" "rc=0" "no record, no call"
}

# ^ invariant ip_win_failed_apply PREAMBLE CODE runs install_path_apply on a fake Windows whose winpath_apply writes nothing (rc 1, "denied"); CODE follows
ip_win_failed_apply() {
    ip_win "$1"'
INSTALL_PATH_NEWREC="windows-user-path ;C:/u/bin" INSTALL_PATH_ACTION=add
winpath_apply() { WINPATH_WHY=denied; return 1; }
install_path_apply; echo "rc=$? $INSTALL_PATH_ACTION"'"$2"
}

# ^ coupled the condition of lc_git_wrapper ends in false => git never fails; its side effect swaps the state dir for a plain file after the hook command
# ^ why a file in place of the dir, not a read-only dir; state_make_dir sets the dir to 0700 again on every write
test_install_exits_1_and_changes_nothing_when_the_state_cannot_be_written_before_the_path_change() {
    local want
    lc_mac_begin || return 1
    want="PATH: could not write the state file $LC_STATE/state before the PATH change; nothing was written to PATH"
    lc_git_wrapper '{ [ "$4" = hook.git-secret-guard.command ] && rm -rf -- "'"${LC_STATE:?}"'" && : >"'"$LC_STATE"'"; false; }' || return 1
    gsg install
    assert_rc 1 "the state could not be written"
    assert_contains "$ERR" "$want" "names the state file"
    assert_eq "$(grep -c -F -- "$want" <<<"$ERR")" 1 "in one line, said once"
    assert_no_zprofile "the startup file was not written"
    assert_contains "$OUT" "add this line to your shell startup file: $ADD_LINE" "the line to add by hand is printed"
    assert_contains "$(gitx config --global --get-all hook.git-secret-guard.event)" "pre-commit" "the hook is installed all the same"
}

# ^ coupled a stand-in mktemp lets the first state write after the hook command through and fails the second, the rewrite of a failed change
# ^ why the marker files sit in pathbin, not in the sandbox; lc_begin clears pathbin and the listing of the sandbox outside the template items stays as it was
ip_fail_the_second_state_write() {
    local real armed="$SANDBOX/pathbin/state.armed" seen="$SANDBOX/pathbin/state.seen" gnubin="$SANDBOX/brewprefix/opt/coreutils/libexec/gnubin"
    real="$(type -P mktemp)" || return 1
    printf '#!/bin/sh\ncase "$1" in */state.*) if [ -f "%s" ]; then if [ -f "%s" ]; then echo "mktemp: injected failure" >&2; exit 1; fi; : >"%s"; fi ;; esac\nexec %s "$@"\n' \
        "$armed" "$seen" "$seen" "$real" >"$SANDBOX/pathbin/mktemp" && chmod 755 "$SANDBOX/pathbin/mktemp" || return 1
    # ^ external on a Mac the CLI has the gnubin of the brew prefix first on PATH => the stand-in goes there too, once the prefix is filled
    if [ -n "$TEST_GNUBIN" ]; then
        lc_brew_have bash coreutils util-linux jq || return 1
        rm -f -- "$gnubin/mktemp" && cp -- "$SANDBOX/pathbin/mktemp" "$gnubin/mktemp" || return 1
    fi
    lc_git_wrapper '{ [ "$4" = hook.git-secret-guard.command ] && : >"'"$armed"'"; false; }'
}

test_install_exits_1_and_says_the_record_is_stale_when_the_state_cannot_be_rewritten_after_a_failed_change() {
    lc_mac_begin || return 1
    ip_readonly_zprofile || return 1
    ip_fail_the_second_state_write || return 1
    gsg install
    assert_rc 1 "the state could not be rewritten"
    assert_contains "$ERR" "could not rewrite the state file $LC_STATE/state" "names the state file"
    assert_contains "$ERR" "cli_path record in it is stale" "says the record is stale"
    assert_eq "$(<"$LC_HOME/.zprofile")" "export A=1" "the file is as it was"
    assert_contains "$(gitx config --global --get-all hook.git-secret-guard.event)" "pre-commit" "the hook is installed all the same"
}

# ^ invariant recorded before made, nothing written = no record; a step before the PATH step stopping install leaves neither a record nor a file
test_an_install_that_stops_before_the_path_step_leaves_no_record_and_no_file() {
    lc_mac_begin || return 1
    lc_git_wrapper '[ "$4" = hook.git-secret-guard.command ]' || return 1
    gsg install
    assert_rc 1 "install stops when the hook command cannot be set"
    assert_no_cli_record "the state records no change that was never made"
    assert_no_zprofile "and the startup file was not written"
}

# ^ coupled the Windows flow with a fake adapter => the state gets the new record before the change; a failed apply writes it again with the carried one
test_the_windows_flow_writes_the_state_with_the_new_record_before_the_change_and_takes_it_back_when_nothing_was_written() {
    local new='windows-user-path ;C:/u/bin' old='windows-user-path ;C:/old' write='install_write_state() { echo "write:$1 record=[$INSTALL_PATH_RECORD]"; }'
    ip_win "$write"'
winpath_apply() { echo "apply record=[$INSTALL_PATH_RECORD]"; return 0; }
ST_CLI_PATH="'"$old"'" INSTALL_PATH_RECORD="'"$old"'" INSTALL_PATH_NEWREC="'"$new"'" INSTALL_PATH_ACTION=add
install_path_apply; echo "rc=$?"'
    assert_eq "$OUT" "write:final record=[$new]"$'\n'"apply record=[$new]"$'\nrc=0' "the state holds the record when the Path is written"
    ip_win_failed_apply "$write"$'\nST_CLI_PATH="'"$old"'"' ""
    assert_eq "$OUT" "write:final record=[$new]"$'\n'"write:final record=[$old]"$'\nrc=0 failed' "nothing written: the state goes again with the earlier record"
    ip_win_failed_apply "$write"$'\nST_CLI_PATH=""' ""
    assert_eq "$OUT" "write:final record=[$new]"$'\nwrite:final record=[]\nrc=0 failed' "no earlier record: the state goes again with none"
    ip_win "$write"'
INSTALL_PATH_NEWREC="'"$new"'" INSTALL_PATH_ACTION=add
winpath_apply() { WINPATH_NOBROADCAST=1; return 0; }; install_path_apply; echo "rc=$?"'
    assert_eq "$OUT" "write:final record=[$new]"$'\nrc=0' "a change written but not announced keeps its record and writes the state once"
    ip_win 'install_write_state() { return 1; }; winpath_apply() { echo called; }
GSG_STATE_FILE=/s/state ST_CLI_PATH="'"$old"'" INSTALL_PATH_RECORD="'"$old"'" INSTALL_PATH_NEWREC="'"$new"'" INSTALL_PATH_ACTION=add
install_path_apply; echo "rc=$? $INSTALL_PATH_ACTION [$INSTALL_PATH_RECORD]"'
    assert_eq "$OUT" "rc=1 failed [$old]" "the state cannot be written first: the Path is not touched, install's status is 1"
    assert_contains "$ERR" "PATH: could not write the state file /s/state before the PATH change; nothing was written to PATH" "and the state file is named"
}

run_file_tests
