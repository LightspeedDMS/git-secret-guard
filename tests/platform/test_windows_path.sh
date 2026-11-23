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

# ^ security the sandbox copy of the script keeps no line that reaches the registry or the broadcast; the four functions are file-backed and wpw_begin counts the lines replaced
# ^ invariant the user Path of the test is two files in the sandbox (value.txt, kind.txt); events.log gets one word per write, delete and broadcast
# ^ invariant the number of lines that differ from the product after the four replacements; each replaced line shows once as removed and once as added
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

# ^ invariant wpw_begin leaves WPW (the sandbox directory) with a copy of bin/gsg-path.ps1 whose four seam functions are the file-backed ones, and no user Path value
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

# ^ invariant wpw_set VALUE KIND stores the test user Path; wpw_none removes it; wpw_value sets WPW_VALUE to the stored bytes exactly and WPW_KIND to the stored type
wpw_set() { printf '%s' "$1" >"$WPW/value.txt" && printf '%s' "$2" >"$WPW/kind.txt"; }
wpw_none() { rm -f -- "$WPW/value.txt" "$WPW/kind.txt"; }
wpw_value() {
    WPW_VALUE="$(cat -- "$WPW/value.txt" && printf x)" || return 1
    WPW_VALUE="${WPW_VALUE%x}"
    WPW_KIND="$(<"$WPW/kind.txt")"
}

# ^ invariant wpw_run VERB ARGS... runs the sandbox copy in Windows PowerShell 5.1; OUT is the status word without its carriage return, ERR the error line, RC the exit status
wpw_run() {
    local script
    script="$(cygpath -w "$WPW/gsg-path.ps1")" || return 1
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" MSYS2_ARG_CONV_EXCL='*' "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass \
        -File "$script" "$@" </dev/null
    OUT="${OUT%$'\r'}"
    ERR="${ERR%$'\r'}"
}

WPW_FOLDER='C:\gsgtest\Ana\.local\bin'
# ^ invariant the exit statuses of bin/gsg-path.ps1 that a test expects: 2 = refused (arguments, registry type, length), 3 = the value no longer fits the plan
WPW_RC_REFUSED=2 WPW_RC_STALE=3

# ^ invariant wpw_install FOLDER does what the adapter does: plan, then apply with the form the plan named; WPW_MODE is that form, OUT and RC are those of the apply
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
    for entry in 'c:\GSGTEST\ana\.LOCAL\BIN' "$WPW_FOLDER\\" "$WPW_FOLDER\\\\" 'C:/gsgtest/Ana/.local/bin' 'C:/gsgtest/Ana/.local/bin/' '%GSG_WPW_BASE%\.local\bin' '%gsg_wpw_base%\.local\bin\'; do
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
    for row in 'ExpandString|%SystemRoot%\system32;C:\Program Files\Git\cmd' 'String|C:\Windows;C:\x y' 'ExpandString|C:\a;;C:\b;' 'String|C:\a;' 'ExpandString|' 'String|;' 'ExpandString|%GSG_WPW_BASE%\bin;%USERPROFILE%\x\'; do
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

run_file_tests
