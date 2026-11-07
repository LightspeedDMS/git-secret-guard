# shellcheck shell=bash disable=SC2034
# ^ coupled the .cmd front end of the CLI on Windows; install-time only, loaded by bin/git-secret-guard after lib/install.sh, never by the hook

GSG_CLI_CMD_MARKER='rem git-secret-guard: written by install, every install rewrites this file'

# ^ external cmd and PowerShell cannot start the bash wrapper => a .cmd beside it; Git's bin\bash.exe sets up PATH, usr\bin\bash.exe does not
# ^ hazard uninstall removes the share under this running file => it deletes itself with the (goto) idiom; a plain rm ends in "batch file cannot be found"
# ^ invariant prints CRLF lines; % is doubled => cmd reads a literal percent sign in a path
install_cli_cmd_text() {
    local root share_win share_mixed bash_win root_win
    root="$(cygpath -w /)" || return 1
    share_win="$(cygpath -w "$GSG_SHARE")" || return 1
    share_mixed="$(cygpath -m "$GSG_SHARE")" || return 1
    root_win="${root%\\}"
    bash_win="$root_win\\bin\\bash.exe"
    # ^ invariant exit 3 plus a hand-off file = a Git for Windows upgrade is prepared; the PowerShell runner does it after bash ended, install runs once more
    # ^ coupled the :half text is the one in bin/gsg-bash.cmd (a test compares them); a stopped installer removes usr/bin/bash.exe and keeps bin/bash.exe
    printf '%s\r\n' '@echo off' "$GSG_CLI_CMD_MARKER" setlocal 'set "GSG_CMD_ENTRY=%~f0"' 'set "GSG_HANDOFF="' \
        'if defined LocalAppData set "GSG_HANDOFF=%LocalAppData%\git-secret-guard\git-upgrade\handoff.txt"' \
        'if defined GSG_HANDOFF if exist "%GSG_HANDOFF%" del /q "%GSG_HANDOFF%" >nul 2>&1' \
        "if not exist \"${root_win//%/%%}\\usr\\bin\\bash.exe\" goto :half" \
        "\"${bash_win//%/%%}\" \"${share_mixed//%/%%}/bin/git-secret-guard\" %*" 'set "GSG_RC=%errorlevel%"' \
        'if "%GSG_RC%"=="3" if defined GSG_HANDOFF if exist "%GSG_HANDOFF%" goto :handoff' \
        "if not exist \"${share_win//%/%%}\\bin\\git-secret-guard\" (goto) 2>nul & del \"%~f0\"" 'exit /b %GSG_RC%' ':handoff' \
        "\"%SystemRoot%\\System32\\WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -ExecutionPolicy Bypass -File \"${share_win//%/%%}\\bin\\gsg-gitup.ps1\" \"%GSG_HANDOFF%\"" \
        'set "GSG_RC=%errorlevel%"' 'if not "%GSG_RC%"=="0" exit /b %GSG_RC%' 'set "GSG_HANDOFF="' 'set "GSG_GIT_UPGRADED=1"' \
        "\"${bash_win//%/%%}\" \"${share_mixed//%/%%}/bin/git-secret-guard\" %*" 'exit /b %errorlevel%' ':half' \
        "if not exist \"${root_win//%/%%}\bin\bash.exe\" goto :gone" \
        ">&2 echo git-secret-guard: Git for Windows at \"${root_win//%/%%}\" looks half installed ^(usr\bin\bash.exe is missing; an installer may have been stopped^); run the installer kept in %LocalAppData%\git-secret-guard\git-upgrade ^(Git-version-64-bit.exe^), or download one from https://git-scm.com/download/win" 'exit /b 127' ':gone' \
        ">&2 echo git-secret-guard: Git for Windows at \"${root_win//%/%%}\" was not found ^(it was removed or moved^); install it from https://git-scm.com/download/win" 'exit /b 127'
}

# ^ invariant true only for a file install_cli_cmd_text wrote; the second line is the marker, whatever paths it names
install_cli_cmd_is_ours() {
    local line
    { read -r line && read -r line; } <"$1" || return 1
    [ "${line%$'\r'}" = "$GSG_CLI_CMD_MARKER" ]
}
