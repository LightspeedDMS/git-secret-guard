# shellcheck shell=bash disable=SC2034
# ^ why a file-wide SC2034 off, not one per line; WINPATH_RECORD and WINPATH_WHY are read by install_path.sh

# ^ coupled seam between lib/install/install_path.sh and the Windows user Path; the flow calls winpath_plan, winpath_apply and winpath_remove only
# ^ coupled the work is done by bin/gsg-path.ps1 under the Windows PowerShell 5.1 of System32; docs/platforms.md has the maintainer notes
# ^ security no value bytes cross the pipe from PowerShell to bash, only status words and exit codes => a Path entry never reaches a log or state this way
WINPATH_RECORD="" WINPATH_WHY="" WINPATH_OUT="" WINPATH_W="" WINPATH_MODE="" WINPATH_FOLDER="" WINPATH_NOBROADCAST=0
GSG_WINPATH_SCRIPT=gsg-path.ps1
# ^ external Windows PowerShell 5.1 sits at this fixed place below System32 on every Windows, PowerShell 7 is never used
GSG_WINPATH_POWERSHELL=WindowsPowerShell/v1.0/powershell.exe
# ^ invariant one start of PowerShell is bounded; a cold start takes a few seconds, the registry work is milliseconds
GSG_WINPATH_SECONDS=60
# ^ external timeout exits with 124 when the command ran out of time
GSG_WINPATH_TIMEOUT_RC=124
# ^ invariant a reason from PowerShell is shown up to this many characters; it is one line of a script of ours, never a value
GSG_WINPATH_REASON_MAX=200

# ^ invariant sets WINPATH_WHY = text $1 with control characters as spaces, cut at GSG_WINPATH_REASON_MAX; the one place a reason is made
winpath_set_why() {
    local t="${1//[[:cntrl:]]/ }"
    WINPATH_WHY="${t:0:GSG_WINPATH_REASON_MAX}"
}

# ^ external System32 is found as the git upgrade finds reg.exe (gitup_windows_sysdir), GSG_GITUP_ROOT moves it in tests, PATH is never searched
# ^ coupled GSG_WINPATH_ROOT is a second explicit override; on Windows GSG_GITUP_ROOT would hide the real reg.exe and whoami.exe from the git upgrade
# ^ invariant sets REPLY = the powershell.exe to run; rc 1 with WINPATH_WHY when the directory or the file is not there
winpath_powershell() {
    local sys root="${GSG_WINPATH_ROOT:-}"
    REPLY=""
    if [ -n "$root" ]; then
        if [ "${root#/}" = "$root" ] || [[ $root == *[[:cntrl:]]* ]] || [[ $root =~ (^|/)\.\.?(/|$) ]]; then
            winpath_set_why "GSG_WINPATH_ROOT must be an absolute path without control characters or . and .. parts"
            return 1
        fi
        sys="${root%/}/windows/System32"
    else
        if ! declare -F gitup_select >/dev/null || ! gitup_select || ! declare -F gitup_windows_sysdir >/dev/null || ! gitup_windows_sysdir; then
            winpath_set_why "the System32 directory cannot be located, so Windows PowerShell cannot be found"
            return 1
        fi
        sys="$REPLY"
    fi
    if [ ! -x "$sys/$GSG_WINPATH_POWERSHELL" ]; then
        winpath_set_why "$sys/$GSG_WINPATH_POWERSHELL was not found"
        return 1
    fi
    REPLY="$sys/$GSG_WINPATH_POWERSHELL"
}

# ^ invariant winpath_run VERB ARGS... runs bin/gsg-path.ps1, sets WINPATH_OUT = its last line (one ASCII status word); rc 1 with WINPATH_WHY otherwise
# ^ why both streams are read and only the last line is used, not stdout alone; a failure prints its one-line reason on stderr and noise before it is ignored
# ^ security MSYS2_ARG_CONV_EXCL keeps the Windows path arguments as they are; stdin is /dev/null and the run is bounded by timeout
winpath_run() {
    local ps script out rc
    WINPATH_OUT=""
    winpath_powershell || return 1
    ps="$REPLY"
    if [ ! -f "$GSG_ROOT/bin/$GSG_WINPATH_SCRIPT" ]; then
        winpath_set_why "$GSG_ROOT/bin/$GSG_WINPATH_SCRIPT is missing"
        return 1
    fi
    if ! script="$(cygpath -w -- "$GSG_ROOT/bin/$GSG_WINPATH_SCRIPT")"; then
        winpath_set_why "cygpath cannot name $GSG_WINPATH_SCRIPT as a Windows path"
        return 1
    fi
    if [ -z "${INSTALL_TIMEOUT_BIN:-}" ]; then
        if ! install_find_bin timeout; then
            winpath_set_why "no timeout command was found"
            return 1
        fi
        INSTALL_TIMEOUT_BIN="$REPLY"
    fi
    out="$(MSYS2_ARG_CONV_EXCL='*' "$INSTALL_TIMEOUT_BIN" "$GSG_WINPATH_SECONDS" "$ps" -NoProfile -ExecutionPolicy Bypass -File "$script" "$@" 2>&1 </dev/null)"
    rc=$?
    out="${out%"${out##*[![:space:]]}"}"
    out="${out##*$'\n'}"
    if [ "$rc" -eq "$GSG_WINPATH_TIMEOUT_RC" ]; then
        winpath_set_why "PowerShell gave no answer within $GSG_WINPATH_SECONDS seconds"
    elif [ "$rc" -ne 0 ]; then
        winpath_set_why "${out:-PowerShell stopped with status $rc and no reason}"
    fi
    [ "$rc" -eq 0 ] || return 1
    WINPATH_OUT="$out"
}

# ^ invariant sets WINPATH_W = folder $1 as an absolute long Windows path; rc 1 with WINPATH_WHY for a name the user Path cannot carry
# ^ why ; % " and control characters are refused, not escaped; ; splits entries, % starts a variable, a quote breaks the argument and nothing here may guess
winpath_folder() {
    local w
    WINPATH_W=""
    if ! w="$(cygpath -w -l -- "$1")"; then
        winpath_set_why "the folder name cannot be written as a Windows path"
        return 1
    fi
    if [[ $w == *[\;%\"[:cntrl:]]* ]]; then
        winpath_set_why "the folder name holds a character the user Path cannot carry (a semicolon, a percent sign, a quote or a control character)"
        return 1
    fi
    if [[ ! $w =~ ^([A-Za-z]:\\|\\\\[^\\]) ]]; then
        winpath_set_why "the folder name is not an absolute Windows path"
        return 1
    fi
    WINPATH_W="$w"
}

# ^ invariant winpath_plan DIR is read-only; REPLY = present (DIR is in the user Path), absent, or unusable (the value cannot be read or changed here)
# ^ invariant for unusable WINPATH_WHY says why; for absent WINPATH_RECORD = "windows-user-path <form text>", see winpath_record for the three forms
# ^ why PowerShell names the form, not the text; the leading separator depends on how the value ends and the value never reaches bash
winpath_plan() {
    REPLY=unusable WINPATH_RECORD=""
    winpath_folder "$1" || return 0
    if ! winpath_run plan "$WINPATH_W"; then
        REPLY=unusable
        return 0
    fi
    case "$WINPATH_OUT" in
        present) REPLY=present ;;
        absent-sep) REPLY=absent WINPATH_RECORD="windows-user-path ;$WINPATH_W" ;;
        absent-bare) REPLY=absent WINPATH_RECORD="windows-user-path $WINPATH_W" ;;
        absent-novalue) REPLY=absent WINPATH_RECORD="windows-user-path created $WINPATH_W" ;;
        *)
            REPLY=unusable
            winpath_set_why "PowerShell gave an unexpected answer to the plan"
            ;;
    esac
}

# ^ invariant $1 = a record; sets WINPATH_MODE (sep, bare or create) and WINPATH_FOLDER; rc 1 with WINPATH_WHY when it is not one of ours
# ^ invariant the forms are "windows-user-path ;FOLDER" (sep, appended after an entry), "windows-user-path FOLDER" (bare, after a final ;) and
# ^ invariant "windows-user-path created FOLDER" is a value install created, uninstall deletes it; FOLDER has no ; % " or control character
winpath_record() {
    local rest="${1#windows-user-path }" re='^([A-Za-z]:\\|\\\\[^\\])[^;%"[:cntrl:]]*$'
    WINPATH_MODE="" WINPATH_FOLDER=""
    case "$rest" in
        ";"*) WINPATH_MODE=sep WINPATH_FOLDER="${rest#;}" ;;
        "created "*) WINPATH_MODE=create WINPATH_FOLDER="${rest#created }" ;;
        *) WINPATH_MODE=bare WINPATH_FOLDER="$rest" ;;
    esac
    if [ "$rest" = "$1" ] || [[ ! $WINPATH_FOLDER =~ $re ]]; then
        WINPATH_MODE="" WINPATH_FOLDER=""
        winpath_set_why "there is no record of a user Path entry of ours to work from"
        return 1
    fi
}

# ^ invariant winpath_apply DIR appends the text of WINPATH_RECORD to the user Path value and keeps its registry type; every other entry stays byte for byte
# ^ invariant rc 0 = appended (WINPATH_NOBROADCAST=1 when running programs were not told), rc 1 = nothing changed (WINPATH_WHY); never a failed install
winpath_apply() {
    WINPATH_NOBROADCAST=0
    winpath_record "$WINPATH_RECORD" || return 1
    winpath_run apply "$WINPATH_MODE" "$WINPATH_FOLDER" || return 1
    case "$WINPATH_OUT" in
        added) ;;
        added-nobroadcast) WINPATH_NOBROADCAST=1 ;;
        *)
            winpath_set_why "PowerShell gave an unexpected answer to the change, so check the user Path"
            return 1
            ;;
    esac
}

# ^ invariant winpath_remove RECORD deletes what apply appended; REPLY = removed, changed (our entry is there in another spelling, left and named) or absent
# ^ invariant rc 1 with WINPATH_WHY when the value could not be written back or RECORD is not ours; an entry the user wrote is never removed
winpath_remove() {
    REPLY=absent WINPATH_NOBROADCAST=0
    winpath_record "$1" || return 1
    winpath_run remove "$WINPATH_MODE" "$WINPATH_FOLDER" || return 1
    case "$WINPATH_OUT" in
        removed) REPLY=removed ;;
        removed-nobroadcast) REPLY=removed WINPATH_NOBROADCAST=1 ;;
        changed | absent) REPLY="$WINPATH_OUT" ;;
        *)
            winpath_set_why "PowerShell gave an unexpected answer to the removal, so check the user Path"
            return 1
            ;;
    esac
}
