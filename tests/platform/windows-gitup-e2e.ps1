# Real-machine scenarios of the Git for Windows upgrade (story #30), for a disposable windows-2025 runner. Never run it on a machine you use:
# it replaces Git for Windows with an old release first, then upgrades it, kills installers and sets global git configuration.
# One scenario per run, chosen by -Scenario; the output ends with 'E2E SUMMARY: N passed, M failed'. The fake credential is built at run time and never printed.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('winget', 'inuse', 'inuse-winget', 'killed', 'signature', 'rerun', 'prompt')]
    [string]$Scenario
)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Continue'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Work = Join-Path $env:RUNNER_TEMP 'gsgwin'
New-Item -ItemType Directory -Force -Path $Work | Out-Null
$GitDir = 'C:\Program Files\Git'
$GitExe = Join-Path $GitDir 'cmd\git.exe'
# The old release the machine starts from; the digest is the one in the SHA-256 table of the release notes v2.53.0.windows.3 (equal to the API digest).
$OldVersion = '2.53.0.3'
$OldSha = 'bc88381e192bd5b17a131755d837828d8a570da1ead89cfcde0d45ae38133c0b'
$OldUrl = "https://github.com/git-for-windows/git/releases/download/v2.53.0.windows.3/Git-$OldVersion-64-bit.exe"
$script:Pass = 0
$script:Fail = 0

function Show([string]$Text) {
    foreach ($line in ($Text -split "`r?`n")) { if ($line.Trim().Length -gt 0) { Write-Host ("        | " + $line) } }
}
function Check([string]$Name, [object]$Cond) {
    if ($Cond) { Write-Host "ok      $Name"; $script:Pass++ } else { Write-Host "FAIL    $Name"; $script:Fail++ }
}
function Finish {
    Write-Host ("E2E SUMMARY: {0} passed, {1} failed" -f $script:Pass, $script:Fail)
    if ($script:Fail -eq 0) { exit 0 } else { exit 1 }
}
function Read-Shared([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return '' }
    $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite,Delete')
    try { return (New-Object System.IO.StreamReader($fs)).ReadToEnd() } finally { $fs.Dispose() }
}
function Git-Version { try { return ((& $GitExe --version) -join ' ').Trim() } catch { return "git does not run: $($_.Exception.Message)" } }
function Pinned-Version {
    foreach ($l in Get-Content (Join-Path $Root 'tools.lock')) {
        if ($l -match '^git-for-windows\s+(\S+)\s+windows_amd64\s+') { return $Matches[1] }
    }
    throw 'no git-for-windows row in tools.lock'
}
function Expected-Git { return ((Pinned-Version) -replace '^(\d+\.\d+\.\d+)\.(\d+)$', '$1.windows.$2') }
function Registry-Version {
    $k = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\Git_is1'
    if (Test-Path $k) { return (Get-ItemProperty $k).DisplayVersion } else { return '(no Git_is1 record)' }
}
function Pending-Git-Renames {
    $p = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue
    $v = $null
    if ($p -and $p.PSObject.Properties['PendingFileRenameOperations']) { $v = $p.PendingFileRenameOperations }
    if (-not $v) { return @() }
    return @($v | Where-Object { $_ -match 'Git' })
}
# The product takes winget when it is on PATH; the installer route (digest, signature, kill, files in use) needs it off PATH for the product process only.
function Hide-Winget {
    $env:PATH = (($env:PATH -split ';') | Where-Object { $_ -notlike '*\Microsoft\WindowsApps*' }) -join ';'
    Check "winget is not on PATH for the product, so it takes the installer route" (-not (Get-Command winget.exe -ErrorAction SilentlyContinue))
}

# Starts the old release over whatever Git for Windows the image has. /ALLOWDOWNGRADE=1 is for this fixture only; the product never passes it.
function Install-OldGit {
    $exe = Join-Path $Work "Git-$OldVersion-64-bit.exe"
    Invoke-WebRequest -Uri $OldUrl -OutFile $exe -UseBasicParsing
    $got = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
    Check "the old installer matches the digest of its release table" ($got -eq $OldSha)
    if ($got -ne $OldSha) { Finish }
    Write-Host "== image git before: $(Git-Version)"
    $p = Start-Process -FilePath $exe -ArgumentList '/VERYSILENT', '/NORESTART', '/SP-', '/ALLOWDOWNGRADE=1' -Wait -PassThru
    Show "old installer exit code $($p.ExitCode)"
    Remove-Item -LiteralPath $exe -Force
    $v = Git-Version
    Show "git now: $v; Git_is1 DisplayVersion: $(Registry-Version)"
    Check "the machine starts with git $OldVersion, older than 2.54" ($v -like '*2.53.0*')
    if ($v -notlike '*2.53.0*') { Finish }
}

# Runs the product CLI through its cmd front end. $Mid is called about once a second until it returns $true; at the timeout the whole tree is killed.
function Invoke-Gsg([string[]]$CliArgs, [int]$TimeoutSec, [scriptblock]$Mid = $null, [string]$Tree = $Root) {
    $out = Join-Path $Work ("gsg-" + [guid]::NewGuid().ToString('N') + '.txt')
    $cli = Join-Path $Tree 'bin\git-secret-guard.cmd'
    $p = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList ('/c ' + $cli + ' ' + ($CliArgs -join ' ') + ' > ' + $out + ' 2>&1') -PassThru -WindowStyle Hidden
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $midDone = $false
    while (-not $p.HasExited -and (Get-Date) -lt $deadline) {
        if ($Mid -and -not $midDone) { $midDone = [bool](& $Mid $p) }
        Start-Sleep -Seconds 1
    }
    $timedOut = -not $p.HasExited
    if ($timedOut) { & taskkill.exe /F /T /PID $p.Id | Out-Null }
    $p.WaitForExit()
    return [pscustomobject]@{ Rc = $p.ExitCode; Out = (Read-Shared $out); TimedOut = $timedOut }
}

function Fake-Key { return ('AKI' + 'A' + 'Q7XK2MWB4HZ5NR3T') }
function Commit-Blocked {
    $d = Join-Path $Work ("repo-" + [guid]::NewGuid().ToString('N'))
    & $GitExe init -q $d | Out-Null
    & $GitExe -C $d config user.name gsg | Out-Null
    & $GitExe -C $d config user.email gsg@example.invalid | Out-Null
    Set-Content -LiteralPath (Join-Path $d 'a.txt') -Value ("aws_access_key_id = " + (Fake-Key)) -Encoding ascii
    & $GitExe -C $d add a.txt | Out-Null
    $o = (& $GitExe -C $d commit -q -m probe 2>&1) -join "`n"
    $rc = $LASTEXITCODE
    $leaked = $o.Contains((Fake-Key))
    Show (($o -split "`n" | Select-Object -First 2) -join "`n")
    return ($rc -ne 0 -and $o -like '*potential secret*' -and -not $leaked)
}
function Assert-No-Key([string]$Name, [string]$Text) { Check $Name (-not $Text.Contains((Fake-Key))) }
function Installer-Files { return ,@(Get-ChildItem -Path (Join-Path $env:LOCALAPPDATA 'git-secret-guard') -Recurse -Filter '*.exe' -ErrorAction SilentlyContinue) }

function Full-Upgrade-Checks($r) {
    Check "install --upgrade-git ends with exit 0" ($r.Rc -eq 0 -and -not $r.TimedOut)
    Check "git is the pinned version afterwards" ((Git-Version) -like "*$(Pinned-Version)*" -or (Git-Version) -like "*$((Pinned-Version) -replace '\.(\d+)$', '.windows.$1')*")
    Check "a commit with a fake key is blocked" (Commit-Blocked)
}

function Scenario-Winget {
    $w = Get-Command winget.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    Show ("winget on PATH: " + $(if ($w) { $w.Source } else { 'no' }))
    Show ("App Installer package: " + ((Get-AppxPackage -AllUsers Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue | ForEach-Object { $_.PackageFullName }) -join ', '))
    Show ("Windows: " + [System.Environment]::OSVersion.VersionString)
    if (-not $w) {
        Write-Host "NOT POSSIBLE: winget is not on PATH of this runner image, so the winget route cannot run here"
        Check "winget absence is recorded as evidence above" $true
        Finish
    }
    Show ((& winget.exe --version) -join ' ')
    $s = (& winget.exe search --id Git.Git --exact --source winget --accept-source-agreements 2>&1) -join "`n"
    Show $s
    Check "winget lists Git.Git" ($s -like '*Git.Git*')
    Install-OldGit
    $r = Invoke-Gsg @('install', '--upgrade-git') 1500
    Show ($r.Out -split "`n" | Select-Object -First 30 | Out-String)
    Check "the plan names the winget route" ($r.Out -like '*winget*')
    Check "winget was run with the planned scope" ($r.Out -like '*--scope*')
    Full-Upgrade-Checks $r
}

function Scenario-InUse([bool]$WithWinget) {
    Install-OldGit
    if (-not $WithWinget) { Hide-Winget }
    $bash = Join-Path $GitDir 'usr\bin\bash.exe'
    $holder = Start-Process -FilePath $bash -ArgumentList '-c "exec sleep 1800"' -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 3
    Check "a Git Bash process holds the Git files open during the upgrade" (-not $holder.HasExited)
    $r = Invoke-Gsg @('install', '--upgrade-git') 900
    Show ($r.Out -split "`n" | Select-Object -Last 25 | Out-String)
    Write-Host ("RESULT inuse: exit {0}, timed out {1}" -f $r.Rc, $r.TimedOut)
    $holderAlive = -not $holder.HasExited
    Show ("holder still running: $holderAlive; installer processes left: " + (@(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like "Git-*" } | ForEach-Object { $_.ProcessName }) -join ","))
    Show ("git: " + (Git-Version) + "; Git_is1: " + (Registry-Version))
    Show ("pending renames naming Git: " + @(Pending-Git-Renames).Count)
    foreach ($gp in @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$GitDir*" })) { Stop-Process -Id $gp.Id -Force -ErrorAction SilentlyContinue }
    Start-Sleep -Seconds 3
    Check "the run finished by itself (the installer neither hung nor was killed by the timeout)" (-not $r.TimedOut)
    if ($r.Rc -ne 0) {
        Write-Host "OBSERVED: the upgrade failed with Git files in use; rerun without the holder to see recovery"
        $r2 = Invoke-Gsg @('install', '--upgrade-git') 900
        Show ($r2.Out -split "`n" | Select-Object -Last 12 | Out-String)
        Full-Upgrade-Checks $r2
    } else {
        Full-Upgrade-Checks $r
    }
}

function Scenario-Killed {
    Install-OldGit
    Hide-Winget
    $script:killed = $false
    $mid = {
        param($proc)
        $inst = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Git-*' -or $_.ProcessName -like 'is-*' -or $_.ProcessName -like '*.tmp' })
        if ($inst.Count -gt 0) {
            Start-Sleep -Seconds 12
            foreach ($i in (Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -like 'Git-*' -or $_.ProcessName -like 'is-*' -or $_.ProcessName -like '*.tmp' })) {
                & taskkill.exe /F /T /PID $i.Id | Out-Null
            }
            $script:killed = $true
            return $true
        }
        return $false
    }
    $r = Invoke-Gsg @('install', '--upgrade-git') 900 $mid
    Show ($r.Out -split "`n" | Select-Object -Last 12 | Out-String)
    Write-Host ("RESULT killed: installer killed {0}, product exit {1}" -f $script:killed, $r.Rc)
    Check "the installer was found running and killed" $script:killed
    Check "the product did not report success" ($r.Rc -ne 0)
    Show ("after the kill: git: " + (Git-Version) + "; Git_is1: " + (Registry-Version) + "; unins000.exe: " + (Test-Path (Join-Path $GitDir 'unins000.exe')))
    Show ("files under Git: " + (@(Get-ChildItem -Recurse -File -ErrorAction SilentlyContinue $GitDir)).Count + "; pending renames naming Git: " + @(Pending-Git-Renames).Count)
    $r2 = Invoke-Gsg @('install', '--upgrade-git') 600
    Show ($r2.Out -split "`n" | Select-Object -Last 8 | Out-String)
    Write-Host ("RESULT killed rerun: exit {0}" -f $r2.Rc)
    if ($r2.Rc -ne 0) {
        Write-Host "OBSERVED: the plain rerun does not recover; the installer file the first run kept is run by hand with the same flags"
        $kept = @(Installer-Files)
        Show ("kept installer: " + (($kept | ForEach-Object { $_.FullName }) -join ', '))
        if ($kept.Count -ge 1) {
            $hp = Start-Process -FilePath $kept[0].FullName -ArgumentList '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-' -Wait -PassThru
            Show "manual installer exit code $($hp.ExitCode); git: $(Git-Version); Git_is1: $(Registry-Version)"
        }
        $r2 = Invoke-Gsg @('install', '--upgrade-git') 900
        Show ($r2.Out -split "`n" | Select-Object -Last 8 | Out-String)
    }
    Full-Upgrade-Checks $r2
}

function Scenario-Signature {
    Install-OldGit
    Hide-Winget
    $sb = Join-Path $Work 'sandbox'
    & robocopy.exe $Root $sb /E /XD .git /NFL /NDL /NJH /NJS /NP | Out-Null
    $lock = Join-Path $sb 'tools.lock'
    $lines = Get-Content $lock | ForEach-Object { if ($_ -match '^# gsg-signer git-for-windows (\S+) ') { "# gsg-signer git-for-windows $($Matches[1]) CN=Not The Pinned Signer, O=Nobody, C=ZZ" } else { $_ } }
    [System.IO.File]::WriteAllText($lock, (($lines -join "`n") + "`n"))
    Check "the sandbox copy pins another signer than the file has" ([bool]((Get-Content $lock) -match "Not The Pinned Signer"))
    $before = Git-Version
    $r = Invoke-Gsg @('install', '--upgrade-git') 900 $null $sb
    Show ($r.Out -split "`n" | Select-Object -Last 12 | Out-String)
    Write-Host ("RESULT signature: exit {0}" -f $r.Rc)
    Check "the runner refuses with exit 10" ($r.Rc -eq 10)
    Check "and names the signer" ($r.Out -like '*signer*')
    Check "git is unchanged" ((Git-Version) -eq $before)
    Check "the installer, which matched its digest, was kept and the message says so" (((Installer-Files).Count -ge 1) -and (($r.Out -like "*kept*") -or ($r.Out -like "*matched*")))
    Show ("installer files kept: " + ((Installer-Files | ForEach-Object { $_.FullName }) -join ', '))
    # the same sandbox with the true pin must go through: the refusal was the pin and nothing else
    $r2 = Invoke-Gsg @('install', '--upgrade-git') 1200 $null $Root
    Full-Upgrade-Checks $r2
}

# The two legs of git-secret-guard.cmd run by hand, so that only the second one can be given a hostile environment: leg 1 (bash, exit 3 and a hand-off),
# the runner, leg 2 with GSG_GIT_UPGRADED=1 and a dead proxy, which makes the scanner downloads of the rerun fail after the upgrade really happened.
function Scenario-Rerun {
    Install-OldGit
    Hide-Winget
    $handoff = Join-Path $env:LOCALAPPDATA 'git-secret-guard\git-upgrade\handoff.txt'
    $bashCmd = Join-Path $Root 'bin\gsg-bash.cmd'
    $cli = Join-Path $Root 'bin\git-secret-guard'
    $env:GSG_HANDOFF = $handoff
    $o1 = Join-Path $Work 'leg1.txt'
    $p1 = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/c $bashCmd $cli install --upgrade-git > $o1 2>&1" -Wait -PassThru -WindowStyle Hidden
    Show ((Read-Shared $o1) -split "`n" | Select-Object -Last 4 | Out-String)
    Check "leg 1 stops with exit 3 and leaves a hand-off" (($p1.ExitCode -eq 3) -and (Test-Path -LiteralPath $handoff))
    $o2 = Join-Path $Work 'runner.txt'
    $ps51 = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $runner = Join-Path $Root 'bin\gsg-gitup.ps1'
    $p2 = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/c $ps51 -NoProfile -ExecutionPolicy Bypass -File $runner $handoff > $o2 2>&1" -Wait -PassThru -WindowStyle Hidden
    Show ((Read-Shared $o2) -split "`n" | Select-Object -Last 4 | Out-String)
    Check "the runner upgrades git (exit 0)" ($p2.ExitCode -eq 0)
    Check "git is the pinned version now" ((Git-Version) -like ("*" + (Expected-Git) + "*"))
    $env:GSG_HANDOFF = ''
    $env:GSG_GIT_UPGRADED = '1'
    $env:HTTPS_PROXY = 'http://127.0.0.1:9'
    $o3 = Join-Path $Work 'leg2.txt'
    $p3 = Start-Process -FilePath "$env:SystemRoot\System32\cmd.exe" -ArgumentList "/c $bashCmd $cli install --upgrade-git > $o3 2>&1" -Wait -PassThru -WindowStyle Hidden
    $t3 = Read-Shared $o3
    Show ($t3 -split "`n" | Select-Object -Last 14 | Out-String)
    Write-Host ("RESULT rerun: leg 2 exit {0}" -f $p3.ExitCode)
    Check "leg 2 refuses (the scanner downloads cannot reach the network)" ($p3.ExitCode -ne 0)
    Check "and does not claim that nothing was changed, git was upgraded before it" ($t3 -notlike '*nothing was changed*')
    Remove-Item Env:HTTPS_PROXY
    Remove-Item Env:GSG_GIT_UPGRADED
    $r = Invoke-Gsg @('install') 900
    Show ($r.Out -split "`n" | Select-Object -Last 6 | Out-String)
    Check "the same command without the hostile environment completes (recovery)" ($r.Rc -eq 0)
    Check "a commit with a fake key is blocked" (Commit-Blocked)
}
$ConptySource = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

public static class GsgPty
{
    [StructLayout(LayoutKind.Sequential)] struct COORD { public short X; public short Y; }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFO { public int cb; public IntPtr lpReserved; public IntPtr lpDesktop; public IntPtr lpTitle; public int dwX; public int dwY; public int dwXSize; public int dwYSize; public int dwXCountChars; public int dwYCountChars; public int dwFillAttribute; public int dwFlags; public short wShowWindow; public short cbReserved2; public IntPtr lpReserved2; public IntPtr hStdInput; public IntPtr hStdOutput; public IntPtr hStdError; }
    [StructLayout(LayoutKind.Sequential)] struct STARTUPINFOEX { public STARTUPINFO StartupInfo; public IntPtr lpAttributeList; }
    [StructLayout(LayoutKind.Sequential)] struct PROCESS_INFORMATION { public IntPtr hProcess; public IntPtr hThread; public int dwProcessId; public int dwThreadId; }

    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle r, out SafeFileHandle w, IntPtr attrs, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern int CreatePseudoConsole(COORD size, SafeFileHandle hIn, SafeFileHandle hOut, uint flags, out IntPtr hPC);
    [DllImport("kernel32.dll")] static extern void ClosePseudoConsole(IntPtr hPC);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, int flags, ref IntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, IntPtr attr, IntPtr value, IntPtr size, IntPtr prev, IntPtr ret);
    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool CreateProcessW(string app, string cmd, IntPtr pa, IntPtr ta, bool inherit, uint flags, IntPtr env, string cwd, ref STARTUPINFOEX si, out PROCESS_INFORMATION pi);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr h, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr h, uint code);

    // Runs cmdline on a pseudo console, types `send` when `expect` has appeared in the output (once), returns the exit code (-1 timeout) and the transcript.
    public static int Run(string cmdline, string cwd, string expect, string send, int timeoutSec, out string transcript)
    {
        SafeFileHandle inR, inW, outR, outW;
        if (!CreatePipe(out inR, out inW, IntPtr.Zero, 0)) throw new Exception("CreatePipe in " + Marshal.GetLastWin32Error());
        if (!CreatePipe(out outR, out outW, IntPtr.Zero, 0)) throw new Exception("CreatePipe out " + Marshal.GetLastWin32Error());
        IntPtr hpc;
        COORD size; size.X = 200; size.Y = 50;
        int hr = CreatePseudoConsole(size, inR, outW, 0, out hpc);
        if (hr != 0) throw new Exception("CreatePseudoConsole hr=" + hr);
        inR.Dispose(); outW.Dispose();
        IntPtr bytes = IntPtr.Zero;
        InitializeProcThreadAttributeList(IntPtr.Zero, 1, 0, ref bytes);
        STARTUPINFOEX si = new STARTUPINFOEX();
        si.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
        si.lpAttributeList = Marshal.AllocHGlobal(bytes);
        if (!InitializeProcThreadAttributeList(si.lpAttributeList, 1, 0, ref bytes)) throw new Exception("InitializeProcThreadAttributeList " + Marshal.GetLastWin32Error());
        if (!UpdateProcThreadAttribute(si.lpAttributeList, 0, (IntPtr)0x00020016, hpc, (IntPtr)IntPtr.Size, IntPtr.Zero, IntPtr.Zero)) throw new Exception("UpdateProcThreadAttribute " + Marshal.GetLastWin32Error());
        PROCESS_INFORMATION pi;
        if (!CreateProcessW(null, cmdline, IntPtr.Zero, IntPtr.Zero, false, 0x00080000, IntPtr.Zero, cwd, ref si, out pi)) throw new Exception("CreateProcess " + Marshal.GetLastWin32Error());
        StringBuilder sb = new StringBuilder();
        FileStream reader = new FileStream(outR, FileAccess.Read, 4096, false);
        FileStream writer = new FileStream(inW, FileAccess.Write, 4096, false);
        Thread t = new Thread(delegate () {
            byte[] buf = new byte[4096];
            try { int n; while ((n = reader.Read(buf, 0, buf.Length)) > 0) { lock (sb) { sb.Append(Encoding.UTF8.GetString(buf, 0, n)); } } } catch (Exception) { }
        });
        t.IsBackground = true; t.Start();
        DateTime end = DateTime.UtcNow.AddSeconds(timeoutSec);
        bool sent = false; int rc = -1;
        while (DateTime.UtcNow < end)
        {
            if (WaitForSingleObject(pi.hProcess, 200) == 0) { uint code; GetExitCodeProcess(pi.hProcess, out code); rc = (int)code; break; }
            if (!sent)
            {
                string soFar; lock (sb) { soFar = sb.ToString(); }
                if (soFar.Contains(expect)) { byte[] b = Encoding.ASCII.GetBytes(send); writer.Write(b, 0, b.Length); writer.Flush(); sent = true; }
            }
        }
        if (rc == -1) TerminateProcess(pi.hProcess, 124);
        ClosePseudoConsole(hpc);
        t.Join(5000);
        lock (sb) { transcript = sb.ToString() + (sent ? "\n[typed: " + send.Trim() + "]" : "\n[nothing typed: the prompt never appeared]"); }
        return rc;
    }
}
'@

function Scenario-Prompt {
    Install-OldGit
    Add-Type -TypeDefinition $ConptySource -Language CSharp
    # Is the pseudo console itself working? A plain cmd echo must come back through it.
    $t0 = ''
    try { $rc0 = [GsgPty]::Run("$env:SystemRoot\System32\cmd.exe /c echo PTYHELLO", $Root, 'PTYHELLO', "`r", 30, [ref]$t0) } catch { $rc0 = -2; $t0 = "EXCEPTION: $($_.Exception.Message)" }
    Show ("echo through the pseudo console: exit $rc0; " + $t0.Length + " characters; " + ($t0 -replace "`e", '<ESC>' -replace '\s+', ' '))
    Check "a pseudo console returns the output of a child process" ($t0 -like '*PTYHELLO*')
    $cli = Join-Path $Root 'bin\git-secret-guard.cmd'
    $transcript = ''
    $rc = [GsgPty]::Run("$env:SystemRoot\System32\cmd.exe /c $cli install", $Root, '[y/N]', "y`r", 1500, [ref]$transcript)
    $clean = [regex]::Replace($transcript, '\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07', '')
    Show ($clean -split "`r?`n" | Select-Object -Last 12 | Out-String)
    Write-Host "RESULT prompt: exit $rc"
    Check "a real prompt appeared on a pseudo console" ($clean -like '*[[]y/N]*')
    Check "a typed y was taken as the consent" ($clean -like '*[[]typed: y]*' -and $clean -notlike '*refus*')
    Check "install ends with exit 0 after the hand-off and the rerun" ($rc -eq 0)
    Assert-No-Key "the transcript holds no fake key" $clean
    Check "git is the pinned version afterwards" ((Git-Version) -like ("*" + (Expected-Git) + "*"))
    # Diagnosis: does MSYS bash see a terminal on a ConPTY, and does any way of starting it change that?
    $probeScript = 'echo T0=$([ -t 0 ] && echo yes || echo no) T2=$([ -t 2 ] && echo yes || echo no) tty=$(tty 2>&1); echo probe-end'
    $variants = @(
        @{ Label = 'bin\bash.exe'; Cmd = "`"$GitDir\bin\bash.exe`" -c `"$probeScript`""; Env = @{} },
        @{ Label = 'usr\bin\bash.exe'; Cmd = "`"$GitDir\usr\bin\bash.exe`" -c `"$probeScript`""; Env = @{} },
        @{ Label = 'usr\bin\bash.exe with MSYS=enable_pcon'; Cmd = "`"$GitDir\usr\bin\bash.exe`" -c `"$probeScript`""; Env = @{ MSYS = 'enable_pcon' } },
        @{ Label = 'winpty usr\bin\bash.exe'; Cmd = "`"$GitDir\usr\bin\winpty.exe`" `"$GitDir\usr\bin\bash.exe`" -c `"$probeScript`""; Env = @{} }
    )
    foreach ($v in $variants) {
        foreach ($k in $v.Env.Keys) { Set-Item -Path "Env:$k" -Value $v.Env[$k] }
        $t = ''
        try { $prc = [GsgPty]::Run($v.Cmd, $Root, 'probe-end', "`r", 60, [ref]$t) } catch { $prc = -2; $t = $_.Exception.Message }
        foreach ($k in $v.Env.Keys) { Remove-Item -Path "Env:$k" }
        $vis = ([regex]::Replace($t, '\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07', '') -replace '\s+', ' ')
        Show ("probe [" + $v.Label + "]: exit $prc; " + $vis)
    }
    Check "a commit with a fake key is blocked" (Commit-Blocked)
}

Write-Host "== Windows scenario: $Scenario ($([System.Environment]::OSVersion.VersionString))"
switch ($Scenario) {
    'winget' { Scenario-Winget }
    'inuse' { Scenario-InUse $false }
    'inuse-winget' { Scenario-InUse $true }
    'killed' { Scenario-Killed }
    'signature' { Scenario-Signature }
    'rerun' { Scenario-Rerun }
    'prompt' { Scenario-Prompt }
}
Finish
