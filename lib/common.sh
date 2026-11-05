# shellcheck shell=bash

# shellcheck disable=SC2034
GSG_NAME=git-secret-guard

# ^ external betterleaks 1.9.0 exits 1 on fatal errors => leaks need their own exit code; default 1 would hide errors as leaks
# ^ coupled lib/scanners/betterleaks.sh:scan_betterleaks and lib/exempt.sh:betterleaks_config_preflight both pass it as --exit-code
# shellcheck disable=SC2034
GSG_BETTERLEAKS_LEAK_RC=42

# ^ coupled these names with lib/exempt.sh:exempt_load and lib/scanners/betterleaks.sh:scan_betterleaks; writer and reader of HEAD's betterleaks files
# shellcheck disable=SC2034
GSG_REPO_GITLEAKS_TOML=repo-gitleaks.toml
# shellcheck disable=SC2034
GSG_REPO_GITLEAKS_IGNORE=repo-gitleaksignore

# ^ coupled lib/doctor_findings.sh (writer and reader of the record) and lib/report.sh:report_reminder_due (the hook); line 1 of every findings record
# shellcheck disable=SC2034
GSG_FINDINGS_MAGIC="git-secret-guard findings 1"

# ^ security clean maps control characters in tool-provided text to "?" => a detector or file name cannot forge terminal output
# shellcheck disable=SC2034
GSG_JQ_CLEAN='def clean: tostring | gsub("[\u0000-\u001f\u007f]"; "?"); '

# ^ security unset before source => an inherited tool path, version, BASH_BIN or GNUBIN_DIR cannot fill a gap (silent bypass)
load_settings() {
    local file="$1"
    unset TRUFFLEHOG_BIN BETTERLEAKS_BIN JQ_BIN SETSID_BIN TASKKILL_BIN TIMEOUT_BIN SYSTEMCTL_BIN LAUNCHCTL_BIN BASH_BIN GNUBIN_DIR SCAN_TIMEOUT_SECONDS \
        DOCTOR_TIMEOUT_SECONDS TRUFFLEHOG_VERSION BETTERLEAKS_VERSION GITLEAKS_BIN GITLEAKS_VERSION
    if [ ! -f "$file" ] || [ ! -r "$file" ]; then
        printf 'settings file is missing or unreadable: %s\n' "$file" >&2
        return 1
    fi
    # shellcheck source=/dev/null
    source "$file" || return 1
    : "${SCAN_TIMEOUT_SECONDS=300}"
    # ^ security no leading zero => GNU timeout reads 00 as no limit, a padded value would switch the scan time limit off
    if [[ ! $SCAN_TIMEOUT_SECONDS =~ ^[1-9][0-9]*$ ]]; then
        printf 'SCAN_TIMEOUT_SECONDS must be a positive integer, got [%s]\n' "$SCAN_TIMEOUT_SECONDS" >&2
        return 1
    fi
    return 0
}

# ^ invariant sets REPLY = first $2 characters of $1 plus "…" when cut, $1 whole otherwise => a cut value never reads as complete
trunc_text() {
    if [ "${#1}" -gt "$2" ]; then
        REPLY="${1:0:$2}…"
    else
        REPLY="$1"
    fi
}

# ^ external git puts detail on tab-indented lines after its "fatal:" line (extension names); first_message keeps at most 5 of them
# ^ invariant sets REPLY = first line of $1 without the hook prefix plus the indented lines after it, one space apart; control characters "?", cut at 200
first_message() {
    local -a lines=()
    local text i rest
    { mapfile -t -n 6 lines <"$1"; } 2>/dev/null || lines=()
    text="${lines[0]:-}"
    text="${text#"$GSG_NAME: "}"
    for ((i = 1; i < ${#lines[@]}; i++)); do
        if [[ ${lines[i]} != [[:blank:]]* ]]; then break; fi
        rest="${lines[i]#"${lines[i]%%[![:blank:]]*}"}"
        if [ -n "$rest" ]; then text+=" $rest"; fi
    done
    text="${text//[[:cntrl:]]/?}"
    trunc_text "$text" 200
}

# ^ external betterleaks 1.9.0 colours its FTL lines even with --no-color; the codes must go before any log line is matched
strip_ansi() {
    if [[ $1 != *$'\e'* ]]; then
        printf '%s' "$1"
        return 0
    fi
    printf '%s' "$1" | LC_ALL=C sed 's/\x1b\[[0-9;]*m//g'
}

# ^ security fields (key=value) can carry the candidate or a URL holding it => only msg words are printed
msg_words() {
    local w out="" i
    local -a words=()
    read -ra words <<<"$1"
    for ((i = 0; i < ${#words[@]}; i++)); do
        w="${words[$i]}"
        if [[ $w =~ ^[A-Za-z_][A-Za-z0-9_.-]*= ]]; then break; fi
        out+="${out:+ }$w"
    done
    printf '%s' "$out"
}

# ^ invariant prints the path the loaded settings hold for a tool, "" when unset; callers load_settings first
settings_tool_bin() {
    case "$1" in
        trufflehog) printf '%s' "${TRUFFLEHOG_BIN:-}" ;;
        betterleaks) printf '%s' "${BETTERLEAKS_BIN:-}" ;;
        jq) printf '%s' "${JQ_BIN:-}" ;;
        setsid) printf '%s' "${SETSID_BIN:-}" ;;
        taskkill) printf '%s' "${TASKKILL_BIN:-}" ;;
        timeout) printf '%s' "${TIMEOUT_BIN:-}" ;;
        systemctl) printf '%s' "${SYSTEMCTL_BIN:-}" ;;
        launchctl) printf '%s' "${LAUNCHCTL_BIN:-}" ;;
        *) return 1 ;;
    esac
}

# ^ external Windows means Git for Windows bash (uname -s MINGW64_NT-*) running native .exe scanners; every other platform keeps the Linux code paths
gsg_is_windows() {
    case "$(uname -s)" in
        MINGW64_NT-*) return 0 ;;
    esac
    return 1
}

# ^ invariant prints the process-control tool of this platform, taskkill on Windows and setsid elsewhere; status and doctor judge it like jq and timeout
gsg_proc_tool_name() {
    if gsg_is_windows; then printf 'taskkill\n'; else printf 'setsid\n'; fi
}

tool_unusable() {
    local label="$1" path="${2:-}"
    if [ -z "$path" ]; then
        printf '%s is not configured in the settings file' "$label"
    elif [ "${path#/}" = "$path" ]; then
        printf '%s must be an absolute path, got [%s]' "$label" "$path"
    elif [ ! -f "$path" ] || [ ! -x "$path" ]; then
        printf '%s is missing or not executable (%s)' "$label" "$path"
    else
        return 1
    fi
    return 0
}

# ^ invariant prints the value hook.git-secret-guard.command must hold, the hook path alone on Linux, "'<bash>' '<hook>'" when a bash is recorded (macOS)
# ^ why the recorded bash is named in the command, not left to the shebang; a git client started from the GUI has /bin/bash 3.2 first on PATH
# ^ see test:test_the_hook_command_names_the_recorded_bash_and_status_accepts_it
hook_command_text() {
    local hook="$1/hooks/secret-scan" bash_bin="${2:-}" q="'" esc="'\\''"
    # ^ external native Windows git rewrites a POSIX path argument to C:/dir/file (probed) => on Windows the hook path is the mixed form
    if [ -z "$bash_bin" ] && gsg_is_windows; then
        cygpath -m "$hook" | tr -d '\n'
        return "${PIPESTATUS[0]}"
    fi
    if [ -z "$bash_bin" ]; then
        printf '%s' "$hook"
        return 0
    fi
    printf "'%s' '%s'" "${bash_bin//$q/$esc}" "${hook//$q/$esc}"
}

# ^ invariant prints BASH_BIN from the settings of the installed share, "" when there is none (Linux, or not installed)
share_recorded_bash() {
    (
        load_settings "$1/settings" >/dev/null 2>&1 || exit 0
        printf '%s' "${BASH_BIN:-}"
    )
}

# ^ external native git hands the hook XDG_* as C:/dir and only HOME, PATH and TMP are turned back; a Windows user also writes C:\dir => one POSIX form
gsg_posix_path() {
    case "$1" in
        [A-Za-z]:[\\/]*)
            if gsg_is_windows; then
                cygpath -u "$1"
                return
            fi
            ;;
    esac
    printf '%s' "$1"
}

# ^ invariant prints the state directory (XDG_STATE_HOME or ~/.local/state, plus git-secret-guard); rc 1 = neither is set; paths_init and the hook both use it
# ^ why one function in common.sh, not a copy in the hook; the hook finds the findings record without loading the CLI-only state library
state_dir_path() {
    if [ -n "${XDG_STATE_HOME:-}" ]; then
        printf '%s/git-secret-guard' "$(gsg_posix_path "$XDG_STATE_HOME")"
    elif [ -n "${HOME:-}" ]; then
        printf '%s/.local/state/git-secret-guard' "$HOME"
    else
        return 1
    fi
}
