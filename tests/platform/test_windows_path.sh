#!/usr/bin/env bash
# shellcheck source=tests/support/lib.sh disable=SC2016
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lib.sh"
# shellcheck source=tests/support/lifecycle.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/lifecycle.sh"
# shellcheck source=tests/support/gitup_windows.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/gitup_windows.sh"
# shellcheck source=tests/support/winpath.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../support/winpath.sh"

if [ "$TEST_IS_WINDOWS" -ne 1 ]; then FILE_SKIP_REASON="runs bin/gsg-path.ps1 with Windows PowerShell 5.1; tests/install/test_winpath.sh covers the adapter everywhere"; fi

# ^ security the sandbox copy keeps no line reaching the registry or the broadcast; four functions are file-backed and wpw_begin counts the lines replaced
# ^ invariant the user Path of the test is two files in the sandbox (value.txt, kind.txt); events.log gets one word per write, delete and broadcast
# ^ invariant the lines differing from the product after the four replacements; each replaced line shows once as removed and once as added
WPW_SEAM_DIFF_LINES=8

# ^ invariant the file-backed text of one seam function; @DIR@ is the sandbox directory as a Windows path
wpw_seam_text() {
    case "$1" in
        Get-UserPath) printf '%s' 'function Get-UserPath { if (-not [System.IO.File]::Exists('"'"'@DIR@\value.txt'"'"')) { return $null }; return @{ Value = [System.IO.File]::ReadAllText('"'"'@DIR@\value.txt'"'"', [System.Text.Encoding]::UTF8); Kind = [System.IO.File]::ReadAllText('"'"'@DIR@\kind.txt'"'"').Trim() } }' ;;
        Set-UserPath) printf '%s' 'function Set-UserPath([string]$Value, [string]$Kind) { [System.IO.File]::WriteAllText('"'"'@DIR@\value.txt'"'"', $Value, [System.Text.UTF8Encoding]::new($false)); [System.IO.File]::WriteAllText('"'"'@DIR@\kind.txt'"'"', $Kind); [System.IO.File]::AppendAllText('"'"'@DIR@\events.log'"'"', "write`n") }' ;;
        Remove-UserPath) printf '%s' 'function Remove-UserPath { [System.IO.File]::Delete('"'"'@DIR@\value.txt'"'"'); [System.IO.File]::Delete('"'"'@DIR@\kind.txt'"'"'); [System.IO.File]::AppendAllText('"'"'@DIR@\events.log'"'"', "delete`n") }' ;;
        Send-EnvironmentChange) printf '%s' 'function Send-EnvironmentChange { if ([System.IO.File]::Exists('"'"'@DIR@\broadcast.fail'"'"')) { throw '"'"'broadcast failed'"'"' }; [System.IO.File]::AppendAllText('"'"'@DIR@\events.log'"'"', "broadcast`n") }' ;;
        *) return 1 ;;
    esac
}

# ^ invariant wpw_begin leaves WPW (the sandbox directory) with a copy of bin/gsg-path.ps1 whose four seam functions are file-backed, and no user Path value
wpw_begin() {
    local dir name text
    WPW="$SANDBOX/wpw"
    rm -rf -- "${WPW:?}" && mkdir -p -- "$WPW" || return 1
    EXTRA_ENV=()
    dir="$(cygpath -w "$WPW")" || return 1
    if [ -z "$dir" ]; then
        fail "no Windows path for the sandbox, the seams would point outside it"
        return 1
    fi
    cp -- "$GSG_PROJECT/bin/gsg-path.ps1" "$WPW/gsg-path.ps1" || return 1
    for name in Get-UserPath Set-UserPath Remove-UserPath Send-EnvironmentChange; do
        text="$(wpw_seam_text "$name")" || return 1
        text="${text//@DIR@/$dir}"
        SEAM="$text" awk -v name="$name" 'index($0, "function " name) == 1 { print ENVIRON["SEAM"]; next } { print }' "$WPW/gsg-path.ps1" >"$WPW/next.ps1" && mv -f -- "$WPW/next.ps1" "$WPW/gsg-path.ps1" || return 1
    done
    if [ "$(diff "$GSG_PROJECT/bin/gsg-path.ps1" "$WPW/gsg-path.ps1" | grep -c '^[<>]')" -ne "$WPW_SEAM_DIFF_LINES" ]; then
        fail "the four seams must replace exactly four lines of the script"
        return 1
    fi
}

# ^ invariant wpw_set VALUE KIND stores the test user Path; wpw_none removes it; wpw_value sets WPW_VALUE to the stored bytes and WPW_KIND to the type
wpw_set() { printf '%s' "$1" >"$WPW/value.txt" && printf '%s' "$2" >"$WPW/kind.txt"; }
wpw_none() { rm -f -- "$WPW/value.txt" "$WPW/kind.txt"; }
wpw_value() {
    WPW_VALUE="$(cat -- "$WPW/value.txt" && printf x)" || return 1
    WPW_VALUE="${WPW_VALUE%x}"
    WPW_KIND="$(<"$WPW/kind.txt")"
}

# ^ invariant wpw_run VERB ARGS... runs the sandbox copy in Windows PowerShell 5.1; OUT is the status word without its CR, ERR the error line, RC the status
wpw_run() {
    local script
    script="$(cygpath -w "$WPW/gsg-path.ps1")" || return 1
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" MSYS2_ARG_CONV_EXCL='*' "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass \
        -File "$script" "$@" </dev/null
    OUT="${OUT%$'\r'}"
    ERR="${ERR%$'\r'}"
}

WPW_FOLDER='C:\gsgtest\Ana\.local\bin'
# ^ invariant exit statuses of bin/gsg-path.ps1 a test expects; 2 = refused (arguments, registry type, length), 3 = the value no longer fits the plan
WPW_RC_REFUSED=2 WPW_RC_STALE=3

# ^ invariant wpw_install FOLDER does what the adapter does, a plan and an apply with the form the plan named; WPW_MODE is the form, OUT and RC are the apply's
wpw_install() {
    wpw_run plan "$1" || return 1
    case "$OUT" in
        absent-sep) WPW_MODE=sep ;;
        absent-bare) WPW_MODE=bare ;;
        absent-novalue) WPW_MODE=create ;;
        *) fail "the plan of [$1] was [$OUT], not a word to apply"; return 1 ;;
    esac
    wpw_run apply "$WPW_MODE" "$1"
}

test_plan_names_the_form_of_the_value_and_writes_nothing() {
    local row value kind word
    wpw_begin || return 1
    for row in 'C:\a|String|absent-sep' 'C:\a;|ExpandString|absent-bare' '|String|absent-bare' ';|String|absent-bare' "C:\\a;$WPW_FOLDER|ExpandString|present"; do
        IFS='|' read -r value kind word <<<"$row"
        wpw_set "$value" "$kind" || return 1
        wpw_run plan "$WPW_FOLDER"
        assert_eq "$OUT|$RC|$ERR" "$word|0|" "plan of [$value] as $kind"
        wpw_value || return 1
        assert_eq "$WPW_VALUE|$WPW_KIND" "$value|$kind" "[$value] is untouched"
    done
    wpw_none
    wpw_run plan "$WPW_FOLDER"
    assert_eq "$OUT|$RC" "absent-novalue|0" "no value at all"
    assert_no_file "$WPW/events.log" "a plan writes and announces nothing"
}

test_every_spelling_of_the_folder_counts_as_present_and_nothing_else_does() {
    local entry
    wpw_begin || return 1
    set_env GSG_WPW_BASE='C:\gsgtest\Ana'
    for entry in 'c:\GSGTEST\ana\.LOCAL\BIN' "$WPW_FOLDER\\" "$WPW_FOLDER\\\\" 'C:/gsgtest/Ana/.local/bin' 'C:/gsgtest/Ana/.local/bin/' '%GSG_WPW_BASE%\.local\bin' "%gsg_wpw_base%\\.local\\bin\\"; do
        wpw_set "C:\\Windows;$entry;C:\\x" ExpandString || return 1
        wpw_run plan "$WPW_FOLDER"
        assert_eq "$OUT" present "[$entry] is the folder"
        wpw_run apply sep "$WPW_FOLDER"
        assert_eq "$RC" "$WPW_RC_STALE" "[$entry] apply finds it and changes nothing"
    done
    for entry in 'C:\gsgtest\Ana\.local\bin2' 'C:\gsgtest\Ana\.local' 'C:\gsgtest\Ana\.local\bin\sub' '%GSG_WPW_BASE%\.local' '%GSG_WPW_UNDEFINED%\.local\bin' ';;'; do
        wpw_set "C:\\Windows;$entry;C:\\x" ExpandString || return 1
        wpw_run plan "$WPW_FOLDER"
        assert_eq "$OUT" absent-sep "[$entry] is another folder"
    done
    assert_no_file "$WPW/events.log" "nothing was written on the way"
}

test_append_then_remove_restores_every_byte_and_the_registry_type() {
    local row kind value after
    wpw_begin || return 1
    set_env GSG_WPW_BASE='C:\gsgtest\Ana'
    for row in 'ExpandString|%SystemRoot%\system32;C:\Program Files\Git\cmd' 'String|C:\Windows;C:\x y' 'ExpandString|C:\a;;C:\b;' 'String|C:\a;' 'ExpandString|' 'String|;' "ExpandString|%GSG_WPW_BASE%\\bin;%USERPROFILE%\\x\\"; do
        IFS='|' read -r kind value <<<"$row"
        wpw_set "$value" "$kind" || return 1
        rm -f -- "$WPW/events.log"
        wpw_install "$WPW_FOLDER"
        assert_eq "$OUT|$RC" "added|0" "[$value] appended"
        wpw_value || return 1
        case "$WPW_MODE" in
            sep) after="$value;$WPW_FOLDER" ;;
            *) after="$value$WPW_FOLDER" ;;
        esac
        assert_eq "$WPW_VALUE|$WPW_KIND" "$after|$kind" "[$value] gained only our entry, the type is kept"
        wpw_run remove "$WPW_MODE" "$WPW_FOLDER"
        assert_eq "$OUT|$RC" "removed|0" "[$value] removed"
        wpw_value || return 1
        assert_eq "$WPW_VALUE|$WPW_KIND" "$value|$kind" "[$value] is back byte for byte"
        assert_eq "$(<"$WPW/events.log")" $'write\nbroadcast\nwrite\nbroadcast' "[$value] each change was announced once"
    done
}

# ^ external Windows accepts a value below 32,767 characters (the limit counts the closing NUL); this is the longest value the script may write
WPW_LONGEST_VALUE=32766
# ^ invariant a value just past the 1024 characters setx cuts at and past the 2048 bytes Microsoft Learn recommends staying under for a user variable
WPW_PAST_1024=1100 WPW_PAST_2048=2100

# ^ invariant wpw_long N KIND stores a user Path of exactly N characters, entries separated by ; and not ending in one
wpw_long() {
    awk -v n="$1" 'BEGIN { s = ""; i = 0; while (length(s) < n) { s = s (i ? ";" : "") "C:\\Program Files\\Entry" i; i++ } s = substr(s, 1, n); if (substr(s, n, 1) == ";") s = substr(s, 1, n - 1) "x"; printf "%s", s }' >"$WPW/value.txt" &&
        printf '%s' "$2" >"$WPW/kind.txt"
}

test_a_missing_value_is_created_and_deleted_again() {
    wpw_begin || return 1
    wpw_install "$WPW_FOLDER"
    assert_eq "$OUT|$RC|$WPW_MODE" "added|0|create" "a user with no Path value gets one"
    wpw_value || return 1
    assert_eq "$WPW_VALUE|$WPW_KIND" "$WPW_FOLDER|ExpandString" "it holds the folder alone and is of the type Windows itself gives a Path"
    wpw_run remove create "$WPW_FOLDER"
    assert_eq "$OUT|$RC" "removed|0" "uninstall"
    assert_no_file "$WPW/value.txt" "the value install created is deleted"
    assert_eq "$(<"$WPW/events.log")" $'write\nbroadcast\ndelete\nbroadcast' "both changes were announced"
}

test_long_values_keep_every_entry_and_the_largest_one_windows_accepts_is_the_limit() {
    local len kind="ExpandString" before entries
    wpw_begin || return 1
    for len in "$WPW_PAST_1024" "$WPW_PAST_2048" $((WPW_LONGEST_VALUE - 1 - ${#WPW_FOLDER})); do
        wpw_long "$len" "$kind" || return 1
        wpw_value || return 1
        before="$WPW_VALUE"
        entries="$(awk -F';' '{ print NF }' <<<"$before")"
        assert_eq "${#before}" "$len" "the test value is $len characters"
        wpw_install "$WPW_FOLDER"
        assert_eq "$OUT|$RC" "added|0" "[$len] appended"
        wpw_value || return 1
        assert_eq "$WPW_VALUE" "$before;$WPW_FOLDER" "[$len] no entry is lost or cut"
        assert_eq "$(awk -F';' '{ print NF }' <<<"$WPW_VALUE")" "$((entries + 1))" "[$len] one entry more"
        wpw_run remove sep "$WPW_FOLDER"
        wpw_value || return 1
        assert_eq "$WPW_VALUE" "$before" "[$len] back as it was"
    done
    wpw_long $((WPW_LONGEST_VALUE - ${#WPW_FOLDER})) "$kind" || return 1
    rm -f -- "$WPW/events.log"
    wpw_run plan "$WPW_FOLDER"
    assert_eq "$RC|$ERR" "$WPW_RC_REFUSED|the user Path would reach $((WPW_LONGEST_VALUE + 1)) characters, more than Windows accepts for one variable" "one character more is refused at the plan"
    wpw_run apply sep "$WPW_FOLDER"
    assert_eq "$RC" "$WPW_RC_REFUSED" "and at the apply"
    assert_no_file "$WPW/events.log" "nothing was written or announced"
}

test_entries_added_after_ours_stay_when_ours_is_removed() {
    local base='C:\a;C:\b' row suffix expect
    wpw_begin || return 1
    for row in ';C:\zzz|C:\a;C:\b;C:\zzz' ';C:\zzz;|C:\a;C:\b;C:\zzz;' ';;|C:\a;C:\b;;' ';%SystemRoot%\x;C:\y|C:\a;C:\b;%SystemRoot%\x;C:\y'; do
        IFS='|' read -r suffix expect <<<"$row"
        wpw_set "$base" String || return 1
        wpw_install "$WPW_FOLDER"
        assert_eq "$OUT" added "[$suffix] ours is on the end"
        printf '%s' "$suffix" >>"$WPW/value.txt" || return 1
        wpw_run remove sep "$WPW_FOLDER"
        assert_eq "$OUT" removed "[$suffix] ours is found in the middle"
        wpw_value || return 1
        assert_eq "$WPW_VALUE|$WPW_KIND" "$expect|String" "[$suffix] only ours and one separator are gone"
    done
    wpw_set "$WPW_FOLDER;C:\\a" ExpandString || return 1
    wpw_run remove sep "$WPW_FOLDER"
    wpw_value || return 1
    assert_eq "$WPW_VALUE" 'C:\a' "ours at the start leaves the rest"
}

test_a_respelled_entry_is_named_and_left_and_a_gone_one_is_absent() {
    local entry
    wpw_begin || return 1
    set_env GSG_WPW_BASE='C:\gsgtest\Ana'
    for entry in 'c:\GSGTEST\ana\.LOCAL\BIN' "$WPW_FOLDER\\" 'C:/gsgtest/Ana/.local/bin' '%GSG_WPW_BASE%\.local\bin'; do
        wpw_set 'C:\a' String || return 1
        wpw_install "$WPW_FOLDER"
        printf '%s' 'C:\a' >"$WPW/value.txt" && printf ';%s' "$entry" >>"$WPW/value.txt" || return 1
        rm -f -- "$WPW/events.log"
        wpw_run remove sep "$WPW_FOLDER"
        assert_eq "$OUT|$RC" "changed|0" "[$entry] is ours, respelled"
        wpw_value || return 1
        assert_eq "$WPW_VALUE" "C:\\a;$entry" "[$entry] is left as it is"
        assert_no_file "$WPW/events.log" "[$entry] nothing was written"
    done
    wpw_set 'C:\a;C:\b' String || return 1
    wpw_run remove sep "$WPW_FOLDER"
    assert_eq "$OUT|$RC" "absent|0" "an entry that is gone"
    wpw_none
    wpw_run remove create "$WPW_FOLDER"
    assert_eq "$OUT|$RC" "absent|0" "a value that is gone"
    assert_no_file "$WPW/events.log" "nothing was written"
}

test_an_apply_whose_value_changed_since_the_plan_writes_nothing() {
    local row mode value
    wpw_begin || return 1
    for row in 'sep|C:\a;' 'sep|@none' 'bare|C:\a' 'create|C:\a'; do
        IFS='|' read -r mode value <<<"$row"
        case "$value" in
            @none) wpw_none ;;
            *) wpw_set "$value" String || return 1 ;;
        esac
        wpw_run apply "$mode" "$WPW_FOLDER"
        assert_eq "$RC" "$WPW_RC_STALE" "[$row] no longer what the plan saw"
        assert_contains "$ERR" "nothing was changed" "[$row] says so"
        assert_no_file "$WPW/events.log" "[$row] nothing was written"
    done
}

test_a_failed_broadcast_is_reported_after_a_successful_write() {
    wpw_begin || return 1
    wpw_set 'C:\a' ExpandString || return 1
    : >"$WPW/broadcast.fail" || return 1
    wpw_install "$WPW_FOLDER"
    assert_eq "$OUT|$RC" "added-nobroadcast|0" "written, and the word says the announcement failed"
    wpw_value || return 1
    assert_eq "$WPW_VALUE" "C:\\a;$WPW_FOLDER" "the value is there"
    wpw_run remove sep "$WPW_FOLDER"
    assert_eq "$OUT|$RC" "removed-nobroadcast|0" "the same for the removal"
    wpw_value || return 1
    assert_eq "$WPW_VALUE" 'C:\a' "and the value is back"
}

test_a_value_of_another_registry_type_and_a_bad_argument_are_refused_with_nothing_written() {
    local row kind
    local -a words
    wpw_begin || return 1
    for kind in MultiString DWord Binary; do
        wpw_set 'C:\a' "$kind" || return 1
        wpw_run plan "$WPW_FOLDER"
        assert_eq "$RC|$ERR" "$WPW_RC_REFUSED|the user Path has the registry type $kind, which this tool does not change" "[$kind] the plan refuses"
        wpw_run apply sep "$WPW_FOLDER"
        assert_eq "$RC" "$WPW_RC_REFUSED" "[$kind] the apply refuses"
        wpw_set "C:\\a;$WPW_FOLDER" "$kind" || return 1
        wpw_run plan "$WPW_FOLDER"
        assert_eq "$OUT|$RC" "present|0" "[$kind] a folder that is there needs no change, so the type does not matter"
        wpw_run remove sep "$WPW_FOLDER"
        assert_eq "$RC" "$WPW_RC_REFUSED" "[$kind] the removal refuses"
        wpw_value || return 1
        assert_eq "$WPW_VALUE|$WPW_KIND" "C:\\a;$WPW_FOLDER|$kind" "[$kind] the value is as it was"
    done
    wpw_set 'C:\a' String || return 1
    for row in 'plan|C:\a;b' 'plan|C:\a%b' 'plan|rel\dir' 'plan' 'frob|C:\x' 'apply|wrong|C:\x' 'remove|sep|rel'; do
        IFS='|' read -ra words <<<"$row"
        wpw_run "${words[@]}"
        assert_eq "$RC" "$WPW_RC_REFUSED" "[$row] is refused"
    done
    assert_no_file "$WPW/events.log" "nothing was written or announced"
}

test_an_unexpected_error_is_exit_1_with_one_line_and_no_status_word() {
    wpw_begin || return 1
    wpw_set 'C:\a' String || return 1
    rm -f -- "$WPW/kind.txt" && mkdir -- "$WPW/kind.txt" || return 1
    wpw_run plan "$WPW_FOLDER"
    assert_eq "$RC|$OUT" "1|" "exit 1 and nothing on stdout"
    assert_contains "$ERR" "unexpected error: " "one line saying so"
    assert_eq "$(wc -l <<<"$ERR" | tr -d ' ')" 1 "and it is one line"
}

test_a_folder_with_a_non_ascii_name_is_applied_and_removed_byte_for_byte() {
    local folder
    folder="$(printf 'C:\\gsgtest\\Jos\xc3\xa9\\.local\\bin')"
    wpw_begin || return 1
    wpw_set 'C:\a' String || return 1
    wpw_install "$folder"
    assert_eq "$OUT|$RC" "added|0" "applied"
    wpw_value || return 1
    assert_eq "$WPW_VALUE" "C:\\a;$folder" "the name came through as the same bytes"
    wpw_run plan "$folder"
    assert_eq "$OUT" present "found again"
    wpw_run remove sep "$folder"
    assert_eq "$OUT|$RC" "removed|0" "removed"
    wpw_value || return 1
    assert_eq "$WPW_VALUE" 'C:\a' "back as it was"
}

test_the_adapter_and_the_script_agree_from_plan_to_removal() {
    local sys
    wpw_begin || return 1
    wp_begin || return 1
    sys="$WPW/sys/windows/System32/WindowsPowerShell/v1.0"
    mkdir -p -- "$WPW/root/bin" "$sys" || return 1
    cp -- "$WPW/gsg-path.ps1" "$WPW/root/bin/gsg-path.ps1" || return 1
    printf '#!/bin/sh\nexec "%s/WindowsPowerShell/v1.0/powershell.exe" "$@"\n' "$TEST_SYSTEM32" >"$sys/powershell.exe" && chmod 755 "$sys/powershell.exe" || return 1
    set_env GSG_WINPATH_ROOT="$WPW/sys"
    wpw_set 'C:\a' String || return 1
    wp 'GSG_ROOT="$1"; winpath_plan "$GSG_BIN_DIR"; echo "plan=$REPLY|$WINPATH_RECORD"; winpath_apply "$GSG_BIN_DIR"; echo "apply=$? nobc=$WINPATH_NOBROADCAST"
winpath_remove "$WINPATH_RECORD"; echo "remove=$? $REPLY"' "$WPW/root" || return 1
    assert_eq "$OUT" "plan=absent|windows-user-path ;$WP_DIR
apply=0 nobc=0
remove=0 removed" "the adapter plans, applies and removes through the real script"
    wpw_value || return 1
    assert_eq "$WPW_VALUE|$WPW_KIND" 'C:\a|String' "and the value is as it was"
    assert_eq "$(<"$WPW/events.log")" $'write\nbroadcast\nwrite\nbroadcast' "each change was announced once"
}

test_a_plain_install_on_windows_reaches_only_the_stand_in() {
    local log="$SANDBOX/xdg/powershell.log"
    lc_begin && lc_make_fixtures && lc_use_fixtures || return 1
    gsg install
    assert_rc 0 "install"
    assert_eq "$(wc -l <"$log" | tr -d ' ')" 1 "the stand-in was called once"
    assert_contains "$(<"$log")" "gsg-path.ps1 plan " "and it was the plan"
    assert_contains "$OUT" "the PowerShell stand-in of the test suite changes nothing" "its reason is the hint's reason"
    assert_eq "$(state_value cli_path)" "" "nothing is recorded"
}

run_file_tests
