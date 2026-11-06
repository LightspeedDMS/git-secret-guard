# shellcheck shell=bash disable=SC2034
# ^ coupled the .cmd front end of the CLI on Windows; install-time only, loaded by bin/git-secret-guard after lib/install.sh, never by the hook

GSG_CLI_CMD_MARKER='rem git-secret-guard: written by install, every install rewrites this file'

# ^ external cmd and PowerShell cannot start the bash wrapper => a .cmd beside it; Git's bin\bash.exe sets up PATH, usr\bin\bash.exe does not
# ^ hazard uninstall removes the share under this running file => it deletes itself with the (goto) idiom; a plain rm ends in "batch file cannot be found"
# ^ invariant prints CRLF lines; % is doubled => cmd reads a literal percent sign in a path
install_cli_cmd_text() {
    local root share_win share_mixed bash_win
    root="$(cygpath -w /)" || return 1
    share_win="$(cygpath -w "$GSG_SHARE")" || return 1
    share_mixed="$(cygpath -m "$GSG_SHARE")" || return 1
    bash_win="${root%\\}\\bin\\bash.exe"
    # ^ invariant exit 3 plus a hand-off file = a Git for Windows upgrade is prepared; the PowerShell runner does it after bash ended, install runs once more
    printf '%s\r\n' '@echo off' "$GSG_CLI_CMD_MARKER" setlocal 'set "GSG_CMD_ENTRY=%~f0"' 'set "GSG_HANDOFF="' \
        'if defined LocalAppData set "GSG_HANDOFF=%LocalAppData%\git-secret-guard\git-upgrade\handoff.txt"' \
        'if defined GSG_HANDOFF if exist "%GSG_HANDOFF%" del /q "%GSG_HANDOFF%" >nul 2>&1' \
        "\"${bash_win//%/%%}\" \"${share_mixed//%/%%}/bin/git-secret-guard\" %*" 'set "GSG_RC=%errorlevel%"' \
        'if "%GSG_RC%"=="3" if defined GSG_HANDOFF if exist "%GSG_HANDOFF%" goto :handoff' \
        "if not exist \"${share_win//%/%%}\\bin\\git-secret-guard\" (goto) 2>nul & del \"%~f0\"" 'exit /b %GSG_RC%' ':handoff' \
        "\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -ExecutionPolicy Bypass -File \"${share_win//%/%%}\\bin\\gsg-gitup.ps1\" \"%GSG_HANDOFF%\"" \
        'set "GSG_RC=%errorlevel%"' 'if not "%GSG_RC%"=="0" exit /b %GSG_RC%' 'set "GSG_HANDOFF="' 'set "GSG_GIT_UPGRADED=1"' \
        "\"${bash_win//%/%%}\" \"${share_mixed//%/%%}/bin/git-secret-guard\" %*" 'exit /b %errorlevel%'
}

# ^ invariant true only for a file install_cli_cmd_text wrote; the second line is the marker, whatever paths it names
install_cli_cmd_is_ours() {
    local line
    { read -r line && read -r line; } <"$1" || return 1
    [ "${line%$'\r'}" = "$GSG_CLI_CMD_MARKER" ]
}
