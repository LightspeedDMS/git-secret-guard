@echo off
rem Runs Git for Windows' bash with these arguments and returns its exit code. The WSL bash in System32 is never used.
setlocal
set "GSG_BASH="
set "GSG_HALF="
for /f "delims=" %%G in ('where git.exe 2^>nul') do if not defined GSG_BASH call :try "%%~dpG..\bin\bash.exe"
if not defined GSG_BASH call :try "%ProgramFiles%\Git\bin\bash.exe"
if not defined GSG_BASH call :try "%LocalAppData%\Programs\Git\bin\bash.exe"
if not defined GSG_BASH goto :missing
"%GSG_BASH%" %*
exit /b %errorlevel%
:missing
rem The path stays inside double quotes: an ampersand in it would end the echo and run the rest of the line.
if defined GSG_HALF >&2 echo git-secret-guard: Git for Windows at "%GSG_HALF%" looks half installed ^(usr\bin\bash.exe is missing; an installer may have been stopped^); run the installer kept in %LocalAppData%\git-secret-guard\git-upgrade ^(Git-version-64-bit.exe^), or download one from https://git-scm.com/download/win
if defined GSG_HALF exit /b 127
>&2 echo git-secret-guard: Git for Windows was not found ^(no bash.exe next to git.exe or in "%ProgramFiles%\Git"^); install it from https://git-scm.com/download/win
exit /b 127
:try
if not exist "%~1" exit /b 0
if exist "%~dp1..\usr\bin\bash.exe" set "GSG_BASH=%~f1"
if defined GSG_BASH exit /b 0
if defined GSG_HALF exit /b 0
rem Only a Git for Windows tree counts as half installed: its Inno setup leaves unins000.exe, and its git.exe sits in cmd; a Cygwin or MSYS tree has neither.
set "GSG_TREE="
if exist "%~dp1..\unins000.exe" set "GSG_TREE=1"
if exist "%~dp1..\cmd\git.exe" set "GSG_TREE=1"
if defined GSG_TREE for %%I in ("%~dp1..") do set "GSG_HALF=%%~fI"
exit /b 0
