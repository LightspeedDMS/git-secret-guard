# ^ external powershell -NoProfile -ExecutionPolicy Bypass -File gsg-gitup.ps1 HANDOFF-FILE does the Git for Windows upgrade install --upgrade-git planned
# ^ hazard it runs outside any Git for Windows bash, as the upgrade replaces it; code of the same user can edit this file and is not defended against
# ^ invariant no environment variable steers its checks; lock and signer are the tools.lock beside bin (only winget is found through PATH), tests change a copy

# ^ invariant exit 0 done; 10 installer refused (digest, signature, link, missing) and nothing ran; 11 elevation declined; 12 installer or winget failed

# ^ invariant exit 13 bad or used hand-off or bad tools.lock; 14 per-user from an elevated prompt; 15 not startable; 16 unexpected; 17 git at the pin
# ^ invariant exit 18 installed version unreadable, nothing ran; exit 1 means powershell itself refused the script
param([Parameter(Mandatory = $true)][string]$Handoff)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
# ^ invariant one definition of the silent flags; lib/gitup_windows.sh holds the same list and a test compares the two
$InstallerFlags = '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-'
$WingetBase = 'upgrade', '--id', 'Git.Git', '--exact', '--silent', '--accept-source-agreements', '--accept-package-agreements'
$Retry = 'git-secret-guard install --upgrade-git'
$AcceptStatus = 'Valid'
$LockPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'tools.lock'
$HandoffKeys = 'route', 'scope', 'version', 'installer'

function Stop-Run([int]$Code, [string]$Text) {
    [Console]::Error.WriteLine("git-secret-guard: $Text")
    exit $Code
}

# ^ invariant the installed Git for Windows version from its setup record (HKLM machine, HKCU user), empty when none; tests replace this one line
function Get-InstalledVersion([string]$Scope) { $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1'; if ($Scope -eq 'user') { $k = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1' }; if (Test-Path -LiteralPath $k) { return [string](Get-ItemProperty -LiteralPath $k).DisplayVersion }; return '' }

function Test-Elevated { return (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }

function Remove-Quietly([string]$Path) {
    if ($Path -and (Test-Path -LiteralPath $Path)) { Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
}

# ^ invariant a hand-off is data; a fixed first line, only the known keys, an installer beside it under the release name, and no digest
function Read-Handoff([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Stop-Run 13 "the hand-off file $Path does not exist (a hand-off is used once); nothing was changed. Run: $Retry" }
    $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8)
    if ($lines.Count -lt 1 -or $lines[0] -cne 'gsg-git-upgrade-handoff 1') { Stop-Run 13 "$Path is not a git-secret-guard hand-off; nothing was changed. Run: $Retry" }
    $h = @{}
    foreach ($l in $lines | Select-Object -Skip 1) {
        if ($l -notmatch '^([a-z0-9]+)=(.*)$') { Stop-Run 13 "$Path has a line that is not key=value; nothing was changed. Run: $Retry" }
        if ($HandoffKeys -notcontains $Matches[1]) { Stop-Run 13 "$Path has the unknown key $($Matches[1]); nothing was changed. Run: $Retry" }
        $h[$Matches[1]] = $Matches[2]
    }
    foreach ($k in 'route', 'scope', 'version') { if (-not $h.ContainsKey($k)) { Stop-Run 13 "$Path lacks $k; nothing was changed. Run: $Retry" } }
    if ($h['route'] -notin 'installer', 'winget') { Stop-Run 13 "$Path names an unknown route; nothing was changed. Run: $Retry" }
    if ($h['scope'] -notin 'machine', 'user') { Stop-Run 13 "$Path names an unknown scope; nothing was changed. Run: $Retry" }
    if ($h['version'] -notmatch '^[0-9]+(\.[0-9]+){2,3}$') { Stop-Run 13 "$Path has an invalid version; nothing was changed. Run: $Retry" }
    if ($h['route'] -eq 'installer') {
        $dir = Split-Path -Parent (Resolve-Path -LiteralPath $Path).ProviderPath
        $want = 'Git-' + $h['version'] + '-64-bit.exe'
        if (-not $h.ContainsKey('installer')) { Stop-Run 13 "$Path lacks the installer; nothing was changed. Run: $Retry" }
        if ((Split-Path -Leaf $h['installer']) -ne $want -or (Split-Path -Parent $h['installer']) -ne $dir) {
            Stop-Run 13 "the installer in $Path is not $want beside the hand-off; nothing was changed. Run: $Retry"
        }
    }
    return $h
}

# ^ security the digest and the signer are the pin in the tools.lock beside bin for the hand-off version, never a value from the hand-off or the environment
# ^ invariant the signer is the lock line "# gsg-signer git-for-windows VERSION SUBJECT", next to the digest row it belongs with
function Get-Pin([string]$Version) {
    if (-not (Test-Path -LiteralPath $LockPath -PathType Leaf)) { Stop-Run 13 "tools.lock was not found at $LockPath; nothing was run. Reinstall git-secret-guard, then run: $Retry" }
    $sha = $null
    $signer = $null
    foreach ($l in Get-Content -LiteralPath $LockPath -Encoding UTF8) {
        $f = -split $l
        if ($f.Count -eq 4 -and $f[0] -ceq 'git-for-windows' -and $f[2] -ceq 'windows_amd64') {
            if ($f[1] -cne $Version) { Stop-Run 13 "tools.lock pins Git for Windows $($f[1]) but the hand-off asks for $Version; nothing was run. Run: $Retry" }
            if ($f[3] -cnotmatch '^[0-9a-f]{64}$') { Stop-Run 13 "the pin in tools.lock is not a SHA-256; nothing was run" }
            $sha = $f[3]
        }
        if ($l -cmatch '^# gsg-signer git-for-windows (\S+) (.+)$' -and $Matches[1] -ceq $Version) { $signer = $Matches[2].Trim() }
    }
    if (-not $sha) { Stop-Run 13 "tools.lock has no git-for-windows windows_amd64 row; nothing was run. Reinstall git-secret-guard, then run: $Retry" }
    if (-not $signer) { Stop-Run 13 "tools.lock has no gsg-signer line for Git for Windows $Version; nothing was run. Reinstall git-secret-guard, then run: $Retry" }
    return @{ Sha = $sha; Signer = $signer }
}

# ^ invariant only the installer file and the two directories install made for it are checked, as lib/gitup_windows.sh does; a link above them is the user's
# ^ order the check runs after the file is open, since an open file stops its directories from being renamed or replaced
function Find-ReparsePoint([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    for ($i = 0; $i -lt 3 -and $p; $i++) {
        $item = Get-Item -LiteralPath $p -Force
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { return $p }
        $p = Split-Path -Parent $p
    }
    return $null
}

# ^ invariant 1223 (ERROR_CANCELLED) alone means the elevation prompt was declined; the cmdlet may wrap it in another exception
function Test-Declined($Exception) {
    for ($e = $Exception; $e; $e = $e.InnerException) {
        if ($e -is [System.ComponentModel.Win32Exception] -and $e.NativeErrorCode -eq 1223) { return $true }
    }
    return $false
}

function Invoke-Winget([hashtable]$H) {
    $w = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $w) { Stop-Run 10 "winget was planned but is not on PATH any more; nothing was changed. Run: $Retry" }
    $wingetArgs = $WingetBase + @('--scope', $H['scope'])
    Remove-Quietly $Handoff
    Write-Host "git-secret-guard: running winget $($wingetArgs -join ' ')"
    try {
        $p = Start-Process -FilePath $w.Source -ArgumentList $wingetArgs -NoNewWindow -Wait -PassThru
    } catch {
        Stop-Run 15 "winget could not be started ($($_.Exception.Message.Trim())); nothing was changed. Run: $Retry"
    }
    if ($p.ExitCode -ne 0) {
        Stop-Run 12 "winget returned $($p.ExitCode); Git for Windows may be unchanged or partly updated, check 'git --version', then run: $Retry"
    }
}

# ^ security defended; the file is open without write or delete sharing from the checks to the installer end, with no link on it or its two directories
# ^ security the SHA-256 must equal the pin, the signature must be valid and by the pinned signer; a file with another digest is deleted, none is started
# ^ security not defended; code of the same user, as it can also edit this script, the hand-off or tools.lock

# ^ external Valid does not prove the certificate is unrevoked, since Windows checks revocation from its cache only here; docs/platforms.md has the facts
function Invoke-Installer([hashtable]$H) {
    $path = $H['installer']
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { Stop-Run 10 "the installer $path is missing; nothing was run. Run: $Retry" }
    $pin = Get-Pin $H['version']
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $kind = $null
    $failure = $null
    try {
        $reparse = Find-ReparsePoint $path
        $sha = [System.Security.Cryptography.SHA256]::Create()
        $got = ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '').ToLowerInvariant()
        $sig = Get-AuthenticodeSignature -LiteralPath $path
        $subject = ''
        if ($sig.SignerCertificate) { $subject = $sig.SignerCertificate.Subject }
        if ($reparse) { $kind = 'link'; $failure = "$reparse is a junction or symbolic link, which could be pointed elsewhere before the start" }
        elseif ($got -cne $pin.Sha) { $kind = 'digest'; $failure = "the SHA-256 of $path is $got, the tools.lock pin is $($pin.Sha)" }
        elseif ($sig.Status.ToString() -cne $AcceptStatus) { $kind = 'signature'; $failure = "the Authenticode signature of $path is $($sig.Status), expected $AcceptStatus ($($sig.StatusMessage))" }
        elseif ($subject -cne $pin.Signer) { $kind = 'signer'; $failure = "the signer of $path is [$subject] and [$($pin.Signer)] is the pin of tools.lock" }
        if (-not $failure) {
            Write-Host "git-secret-guard: SHA-256 and signature of $(Split-Path -Leaf $path) verified"
            $have = Get-InstalledVersion $H['scope']
            $haveV = $null
            if ($have -and -not [version]::TryParse($have, [ref]$haveV)) { $kind = 'unreadable'; $failure = "the installed Git for Windows version [$have] cannot be read as a version" }
            elseif ($have -and $haveV -ge [version]$H['version']) { $kind = 'current'; $failure = "Git for Windows $have is already installed, which is not older than the pinned $($H['version'])" }
        }
        if (-not $failure) {
            Remove-Quietly $Handoff
            Write-Host "git-secret-guard: starting $(Split-Path -Leaf $path) with $($InstallerFlags -join ' ')"
            $params = @{ FilePath = $path; ArgumentList = $InstallerFlags; Wait = $true; PassThru = $true }
            if ($H['scope'] -eq 'machine' -and -not (Test-Elevated)) { $params['Verb'] = 'RunAs' }
            try {
                $p = Start-Process @params
            } catch {
                if (Test-Declined $_.Exception) {
                    $kind = 'declined'
                } else {
                    $kind = 'start'
                    $failure = $_.Exception.Message.Trim()
                }
            }
        }
    } finally {
        $stream.Dispose()
    }
    if ($kind -eq 'declined') { Stop-Run 11 "the elevation prompt was declined, so the installer did not start and nothing was changed. Run: $Retry" }
    if ($kind -eq 'start') { Stop-Run 15 "the installer could not be started ($failure); nothing was changed. Run: $Retry" }
    if ($kind -eq 'unreadable') {
        Remove-Quietly $Handoff
        Stop-Run 18 "$failure, so it cannot be compared with the pinned $($H['version']); the installer was NOT run and Git for Windows is unchanged. Install Git for Windows by hand from https://git-scm.com/download/win, then run install again"
    }
    if ($kind -eq 'current') {
        Remove-Quietly $Handoff
        Remove-Quietly $path
        Stop-Run 17 "$failure; nothing was run and nothing is needed (this hand-off is older than the git on this machine). The installer would only offer a downgrade, and this tool never allows one. Run install again if you want the rest of install: git-secret-guard install"
    }
    if ($kind -eq 'link') {
        Remove-Quietly $Handoff
        Stop-Run 10 "$failure; the installer was NOT run and Git for Windows is unchanged. Remove or replace that directory link, then run: $Retry"
    }
    if ($kind -eq 'digest') {
        Remove-Quietly $path
        Remove-Quietly $Handoff
        Stop-Run 10 "$failure; the installer was NOT run, the file was deleted and Git for Windows is unchanged. Run: $Retry"
    }
    if ($kind -eq 'signer') {
        Remove-Quietly $Handoff
        Stop-Run 10 "$failure; the file matches the pinned SHA-256 and its signature is $AcceptStatus, so this is a pin that does not describe the file, not a problem of this machine. The installer was NOT run and Git for Windows is unchanged. Report it, and install Git for Windows by hand from https://git-scm.com/download/win meanwhile"
    }
    if ($kind -eq 'signature') {
        Remove-Quietly $Handoff
        Stop-Run 10 "$failure; the file matches the pinned SHA-256, so downloading it again will not help. The installer was NOT run and Git for Windows is unchanged. This machine cannot validate the vendor signature (certificate chain or clock); install Git for Windows by hand from https://git-scm.com/download/win, then run install again"
    }
    if ($p.ExitCode -ne 0) {
        Stop-Run 12 "the installer returned $($p.ExitCode); Git for Windows may be unchanged or partly updated, check 'git --version', then run: $Retry"
    }
    Remove-Quietly $path
}

try {
    $h = Read-Handoff $Handoff
    if ($h['scope'] -eq 'user' -and (Test-Elevated)) {
        Stop-Run 14 "Git for Windows is installed for this user only and this prompt is elevated; an elevated installer could install machine-wide. Open a normal prompt and run: $Retry. Nothing was run."
    }
    if ($h['route'] -eq 'winget') { Invoke-Winget $h } else { Invoke-Installer $h }
    Write-Host "git-secret-guard: the Git for Windows upgrade finished; open a new terminal to see the new PATH"
} catch {
    Stop-Run 16 "unexpected error in the upgrade runner: $($_.Exception.Message.Trim()). Check 'git --version', then run: $Retry"
}
exit 0
