@echo off
rem git-secret-guard for cmd and PowerShell. Same commands as the Git Bash CLI.
rem Exit 3 plus a hand-off file means bash prepared a Git for Windows upgrade: run it from here, outside bash, then run the command once more.
setlocal
set "GSG_HANDOFF="
if defined LocalAppData set "GSG_HANDOFF=%LocalAppData%\git-secret-guard\git-upgrade\handoff.txt"
if defined GSG_HANDOFF if exist "%GSG_HANDOFF%" del /q "%GSG_HANDOFF%" >nul 2>&1
call "%~dp0gsg-bash.cmd" "%~dp0git-secret-guard" %*
set "GSG_RC=%errorlevel%"
if "%GSG_RC%"=="3" if defined GSG_HANDOFF if exist "%GSG_HANDOFF%" goto :handoff
exit /b %GSG_RC%
:handoff
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "%~dp0gsg-gitup.ps1" "%GSG_HANDOFF%"
set "GSG_RC=%errorlevel%"
if not "%GSG_RC%"=="0" exit /b %GSG_RC%
set "GSG_HANDOFF="
set "GSG_GIT_UPGRADED=1"
call "%~dp0gsg-bash.cmd" "%~dp0git-secret-guard" %*
exit /b %errorlevel%
