@echo off
rem Runs the test suite from cmd or PowerShell: tests\run.cmd [FILE...]. See CONTRIBUTING.md.
call "%~dp0..\bin\gsg-bash.cmd" "%~dp0run.sh" %*
exit /b %errorlevel%
