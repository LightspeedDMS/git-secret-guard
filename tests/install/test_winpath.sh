#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup_windows.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup_windows.sh"

# shellcheck source=tests/support/winpath.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/winpath.sh"

test_plan_maps_each_status_word_to_the_answer_and_the_record_install_keeps() {
    local row word reply expect
    for row in "present|present|" "absent-sep|absent|windows-user-path ;$WP_DIR" "absent-bare|absent|windows-user-path $WP_DIR" "absent-novalue|absent|windows-user-path created $WP_DIR"; do
        IFS='|' read -r word reply expect <<<"$row"
        wp_begin || return 1
        wp_say plan "$word" || return 1
        wp 'winpath_plan "$GSG_BIN_DIR"; echo "$REPLY|$WINPATH_RECORD"'
        assert_eq "$OUT" "$reply|$expect" "the status word [$word]"
        assert_contains "$(wp_log)" "-NoProfile -ExecutionPolicy Bypass -File " "PowerShell starts without profile, policy bypassed for this one script"
        assert_contains "$(wp_log)" "gsg-path.ps1 plan $WP_DIR" "the script gets the verb and the folder as a Windows path, nothing else"
    done
}

test_plan_refuses_a_folder_the_user_path_cannot_hold_without_starting_powershell() {
    local name dir
    for name in semicolon percent quote newline tab relative; do
        case "$name" in
            semicolon) dir='/c/a;b' ;;
            percent) dir='/c/a%b' ;;
            quote) dir='/c/a"b' ;;
            newline) dir=$'/c/a\nb' ;;
            tab) dir=$'/c/a\tb' ;;
            relative) dir='relative/dir' ;;
        esac
        # ^ external NTFS forbids a quote, a newline and a tab in a name and the Windows command line cannot carry them to bash; only Linux builds these
        if [ "$TEST_IS_WINDOWS" -eq 1 ] && [[ $name == quote || $name == newline || $name == tab ]]; then continue; fi
        wp_begin || return 1
        wp_say plan absent-sep || return 1
        wp 'winpath_plan "$1"; echo "$REPLY|$WINPATH_RECORD|$WINPATH_WHY"' "$dir"
        assert_contains "$OUT" "unusable||" "[$name] is not a folder to add"
        assert_contains "$OUT" "the folder name" "[$name] says why"
        assert_eq "$(wp_log)" "" "[$name] PowerShell never started"
    done
}

# ^ invariant wp_unusable NAME TEXT runs the plan on a stand-in the caller set up for NAME; nothing may be planned and the reason must hold TEXT
wp_unusable() {
    wp 'winpath_plan "$GSG_BIN_DIR"; echo "$REPLY|[$WINPATH_RECORD]"; echo "$WINPATH_WHY"'
    assert_contains "$OUT" "unusable|[]" "[$1] nothing is planned"
    assert_contains "$OUT" "$2" "[$1] the reason"
}

test_plan_says_unusable_with_the_reason_when_powershell_cannot_answer() {
    local long
    wp_begin || return 1
    wp_say plan "" 2 "the value is a kind this tool will not touch" || return 1
    wp_unusable exit-code "the value is a kind this tool will not touch"
    wp_say plan "something else" 0 || return 1
    wp_unusable junk-output "unexpected answer"
    rm -f -- "$WU_DIR/root/windows/System32/WindowsPowerShell/v1.0/powershell.exe"
    wp_unusable missing "powershell.exe"
    wp_begin || return 1
    long="$(printf 'boom\001%0*d' "$WP_LONG_REASON_LENGTH" 7)"
    wp_say plan "" 1 "$long" || return 1
    wp_unusable noisy-reason "boom "
    assert_not_contains "$OUT" $'\001' "control characters never reach the output"
    assert_not_contains "$OUT" "$(printf '%0*d' "$WP_PAST_THE_CUT" 7)" "a long reason is cut"
}

# ^ coupled GSG_WINPATH_ROOT moves the System32 winpath looks in, as GSG_GITUP_ROOT does for the git upgrade; lifecycle tests on Windows point it at a stand-in
test_the_powershell_comes_from_the_system32_the_git_upgrade_uses_and_a_root_override_moves_it() {
    local ps="WindowsPowerShell/v1.0/powershell.exe"
    wp_begin || return 1
    wp_say plan present || return 1
    wp 'winpath_plan "$GSG_BIN_DIR"; echo "$REPLY"'
    assert_eq "$OUT" present "found below GSG_GITUP_ROOT, the way gitup_windows_sysdir finds reg.exe"
    rm -rf -- "${WU_DIR:?}/alt" && mkdir -p -- "$WU_DIR/alt/windows/System32/${ps%/*}" || return 1
    mv -- "$WU_DIR/root/windows/System32/$ps" "$WU_DIR/alt/windows/System32/$ps" || return 1
    set_env GSG_WINPATH_ROOT="$WU_DIR/alt"
    wp 'winpath_plan "$GSG_BIN_DIR"; echo "$REPLY"'
    assert_eq "$OUT" present "found below GSG_WINPATH_ROOT when it is set"
    set_env GSG_WINPATH_ROOT="relative/dir"
    wp 'winpath_plan "$GSG_BIN_DIR"; echo "$REPLY|$WINPATH_WHY"'
    assert_contains "$OUT" "unusable|" "a root that is not an absolute path is refused"
    assert_contains "$OUT" "GSG_WINPATH_ROOT" "and named"
}

# ^ invariant the seam is announced like every other test seam, once per run, with its value; a run without it prints nothing
test_the_root_override_is_announced_once_and_a_plain_run_is_silent() {
    wp_begin || return 1
    wp_say plan present || return 1
    wp 'winpath_plan "$GSG_BIN_DIR"; winpath_plan "$GSG_BIN_DIR"'
    assert_not_contains "$ERR" "GSG_WINPATH_ROOT=" "no override set, nothing announced"
    set_env GSG_WINPATH_ROOT="$WU_DIR/root"
    wp 'winpath_plan "$GSG_BIN_DIR"; winpath_plan "$GSG_BIN_DIR"'
    assert_contains "$ERR" "TEST OVERRIDE active (GSG_WINPATH_ROOT=[$WU_DIR/root]); Windows PowerShell is looked for below that folder" "announced with its value"
    assert_eq "$(grep -c "GSG_WINPATH_ROOT=" <<<"$ERR")" 1 "once for two calls"
}

test_the_script_is_plain_ascii_lf_and_never_reaches_the_machine_path_or_setx() {
    local f="$GSG_PROJECT/bin/gsg-path.ps1"
    assert_file "$f" "the script ships in bin, which the share copies"
    assert_eq "$(tr -cd '\r' <"$f" | wc -c | tr -d ' ')" 0 "LF like every file that is not a batch file"
    assert_eq "$(LC_ALL=C tr -d '\000-\177' <"$f" | wc -c | tr -d ' ')" 0 "plain ASCII, which Windows PowerShell 5.1 reads without a byte order mark"
    assert_eq "$(grep -v '^#' "$f" | grep -ciE 'setx|HKLM|LocalMachine|SetEnvironmentVariable\([^)]*Machine|GetEnvironmentVariable|\$env:')" 0 "no setx, no machine hive, no expanded read, no environment variable"
    assert_contains "$(<"$f")" "DoNotExpandEnvironmentNames" "the value is read raw"
}

# ^ invariant two probes; apply reads the record from WINPATH_RECORD, remove takes it as argument; $1 is the record, the answer is "rc=N [answer] nobc=0|1"
# ^ invariant WP_WHY_CODE added to a probe also prints the reason
WP_APPLY_CODE='WINPATH_RECORD="$1"; winpath_apply "$GSG_BIN_DIR"; echo "rc=$? nobc=$WINPATH_NOBROADCAST"'
WP_REMOVE_CODE='winpath_remove "$1"; echo "rc=$? $REPLY nobc=$WINPATH_NOBROADCAST"'
WP_WHY_CODE='; echo "$WINPATH_WHY"'

# ^ invariant wp_forms apply|remove WORD runs winpath_apply or winpath_remove for each record form on a stand-in answering WORD; OUT is the last answer
# ^ invariant for each form the script must have been started with exactly the verb, the form word and the folder, in this order
wp_forms() {
    local verb="$1" word="$2" row mode rec log
    local -A probe=([apply]="$WP_APPLY_CODE" [remove]="$WP_REMOVE_CODE")
    for row in "sep|windows-user-path ;$WP_DIR" "bare|windows-user-path $WP_DIR" "create|windows-user-path created $WP_DIR"; do
        IFS='|' read -r mode rec <<<"$row"
        wp_begin || return 1
        wp_say "$verb" "$word" || return 1
        wp "${probe[$verb]:?wp_forms knows apply and remove}" "$rec" || return 1
        log="$(wp_log)"
        assert_eq "${log##*gsg-path.ps1 }" "$verb $mode $WP_DIR" "[$verb $mode] the script gets the form of the record and the folder, nothing else"
    done
}

test_apply_hands_the_script_the_form_and_the_folder_of_the_record_and_reports_the_outcome() {
    wp_forms apply added || return 1
    assert_eq "$OUT" "rc=0 nobc=0" "appended"
    wp_say apply added-nobroadcast || return 1
    wp "$WP_APPLY_CODE" "windows-user-path ;$WP_DIR" || return 1
    assert_eq "$OUT" "rc=0 nobc=1" "a change written but not announced is still a success and says so"
}

test_apply_that_changes_nothing_says_why_and_never_fails_the_install() {
    wp_begin || return 1
    wp_say apply "" 3 "the user Path changed while install ran; nothing was changed" || return 1
    wp "$WP_APPLY_CODE$WP_WHY_CODE" "windows-user-path ;$WP_DIR" || return 1
    assert_contains "$OUT" "rc=1" "nothing changed"
    assert_contains "$OUT" "the user Path changed while install ran" "the script's reason"
    wp "$WP_APPLY_CODE$WP_WHY_CODE" "" || return 1
    assert_contains "$OUT" "rc=1" "no record, nothing to apply"
    assert_contains "$OUT" "no record" "and says so"
    assert_eq "$(wp_log | wc -l | tr -d ' ')" 1 "PowerShell ran once, for the first call only"
    wp 'install_write_state() { return 0; }; GSG_NAME=git-secret-guard WINPATH_RECORD="windows-user-path ;$1" INSTALL_PATH_ACTION=add; install_path_apply; echo "install=$?"; install_path_report' "$WP_DIR" || return 1
    assert_contains "$OUT" "install=0" "the install step itself succeeds"
    assert_contains "$OUT" "is not on PATH (the user Path changed while install ran; nothing was changed)" "install_path_report prints the hint with the reason"
    assert_contains "$OUT" "add $WP_DIR to the Path of your Windows user" "and the step to do by hand"
}

test_remove_reports_what_the_script_did_and_names_the_form_and_folder_it_recorded() {
    local row word reply nobc
    for row in "removed|removed|0" "removed-nobroadcast|removed|1" "changed|changed|0" "absent|absent|0"; do
        IFS='|' read -r word reply nobc <<<"$row"
        wp_forms remove "$word" || return 1
        assert_eq "$OUT" "rc=0 $reply nobc=$nobc" "the status word [$word]"
    done
}

test_remove_fails_with_the_reason_when_the_value_cannot_be_written_back_and_never_touches_a_record_it_does_not_know() {
    local rec
    wp_begin || return 1
    wp_say remove "" 1 "access to the registry key was denied" || return 1
    wp "$WP_REMOVE_CODE$WP_WHY_CODE" "windows-user-path ;$WP_DIR" || return 1
    assert_contains "$OUT" "rc=1" "a failed write is a failed uninstall step"
    assert_contains "$OUT" "access to the registry key was denied" "with the reason"
    for rec in "windows-user-path " "windows-user-path relative\\dir" "macos-block 1 0 /x" "windows-user-path ;a;b"; do
        wp_begin || return 1
        wp "$WP_REMOVE_CODE" "$rec" || return 1
        assert_contains "$OUT" "rc=1" "[$rec] is not a record of ours"
        assert_eq "$(wp_log)" "" "[$rec] PowerShell never started"
    done
}

run_file_tests
