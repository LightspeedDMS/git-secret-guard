@echo off
rem git-secret-guard for cmd and PowerShell. Same commands as the Git Bash CLI.
call "%~dp0gsg-bash.cmd" "%~dp0git-secret-guard" %*
exit /b %errorlevel%
