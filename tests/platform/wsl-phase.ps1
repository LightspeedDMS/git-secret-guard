# Runs one phase of tests/platform/wsl-ci.sh inside the WSL distribution named by WSL_TARGET, as USER. Used only by .github/workflows/wsl.yml.
# WSLENV (set by the workflow) carries WS, MAIN, LOGS, GITHUB_ACTIONS and CONSENT into the distribution; the command has no quotes, so no argument is mangled on the way.
param(
    [Parameter(Mandatory = $true)][string]$Phase,
    [string]$User = 'gsg',
    [string]$PhaseArg = ''
)
$ErrorActionPreference = 'Stop'
if (-not $env:WSL_TARGET) { throw 'WSL_TARGET is not set' }
if ($User -notmatch '^[a-z][a-z0-9_-]*$') { throw "bad user [$User]" }
$inner = 'bash $WS/tests/platform/wsl-ci.sh $0 $1'
& wsl.exe --distribution $env:WSL_TARGET --user $User --exec bash -c $inner $Phase $PhaseArg
exit $LASTEXITCODE
