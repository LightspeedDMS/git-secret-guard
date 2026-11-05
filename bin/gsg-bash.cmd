@echo off
rem Runs Git for Windows' bash with these arguments and returns its exit code. The WSL bash in System32 is never used.
setlocal
set "GSG_BASH="
for /f "delims=" %%G in ('where git.exe 2^>nul') do if not defined GSG_BASH call :try "%%~dpG..\bin\bash.exe"
if not defined GSG_BASH call :try "%ProgramFiles%\Git\bin\bash.exe"
if not defined GSG_BASH call :try "%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined GSG_BASH goto :missing
"%GSG_BASH%" %*
exit /b %errorlevel%
:missing
>&2 echo git-secret-guard: Git for Windows was not found ^(no bash.exe next to git.exe or in %ProgramFiles%\Git^); install it from https://git-scm.com/download/win
exit /b 127
:try
if exist "%~1" set "GSG_BASH=%~f1"
exit /b 0
