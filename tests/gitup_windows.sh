#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2034
# ^ order sourced after tests/lib.sh => the helpers here build on run_cap, set_env and the sandbox
# ^ security the registry, whoami, winget and curl are recording stand-ins in a sandbox directory; the module finds the system ones only through GSG_GITUP_ROOT

# ^ external Linux has no cygpath; the stand-in maps /c/x to C:\x and any other path below C:\fake, enough for the module's string work
WU_FAKE_CYGPATH='cygpath() {
    local p="$2" rest
    case "$1" in
        -u) case "$p" in
                [Cc]:\\[Ff][Aa][Kk][Ee]*) p="${p:7}"; printf "%s\n" "${p//\\//}" ;;
                [A-Za-z]:*) rest="${p:2}"; printf "/%s%s\n" "${p:0:1}" "${rest//\\//}" ;;
                *) printf "%s\n" "$p" ;;
            esac ;;
        *) case "$p" in
               /[a-z]/*) rest="${p:2}"; p="${p:1:1}"; printf "%s:%s\n" "${p^^}" "${rest//\//\\}" ;;
               *) printf "C:\\\\fake%s\n" "${p//\//\\}" ;;
           esac ;;
    esac
}'
if ! type -P cygpath >/dev/null; then eval "$WU_FAKE_CYGPATH"; fi

# ^ invariant the libraries the CLI loads for install plus the shared git upgrade core; the module itself is loaded by gitup_select from the registry
WU_PRELUDE='set -u
GSG_ROOT="$1"; GSG_NAME=git-secret-guard; GSG_UNINSTALL_ACTIONS=0
uname() { if [ "${1:-}" = -m ]; then echo x86_64; else echo MINGW64_NT-10.0-26200; fi; }
type -P cygpath >/dev/null || eval "$WU_FAKE_CYGPATH"
for lib in brew common state tools hookspath install install_cmd install_tools uninstall gitup gitup_source; do source "$GSG_ROOT/lib/$lib.sh" || exit 9; done
INSTALL_TIMEOUT_BIN="$(type -P timeout)"
shift
'

wu() {
    local code="$1"
    shift
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" WU_FAKE_CYGPATH="$WU_FAKE_CYGPATH" bash -c "$WU_PRELUDE$code" _ "$GSG_PROJECT" "$@"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}

# ^ security every path a test creates, links or removes lies below the sandbox; an empty variable would otherwise become a path at the root of the file system
# ^ invariant refuses (rc 1, message on stderr) an empty path, a relative one, one with a .. component, or one not below $SANDBOX/; a caller returns 1 on it
wu_sandbox_path() {
    local p
    if [ -z "${SANDBOX:-}" ]; then
        printf 'wu_sandbox_path: SANDBOX is empty\n' >&2
        return 1
    fi
    for p in "$@"; do
        if [ -z "$p" ] || [ "${p#"$SANDBOX"/}" = "$p" ] || [[ /$p/ == */../* ]] || [[ $p == *[[:cntrl:]]* ]]; then
            printf 'wu_sandbox_path: refusing [%s], it is empty or not below the sandbox\n' "$p" >&2
            return 1
        fi
    done
}

# ^ invariant a junction made and removed with cmd; both paths must pass wu_sandbox_path, and removing a junction (rmdir) never reaches its target
wu_mklink() {
    wu_sandbox_path "$1" "$2" || return 1
    "$TEST_SYSTEM32/cmd.exe" //c mklink //J "$(cygpath -w "$1")" "$(cygpath -w "$2")" >/dev/null
}

wu_rmlink() {
    wu_sandbox_path "$1" || return 1
    "$TEST_SYSTEM32/cmd.exe" //c rmdir "$(cygpath -w "$1")" >/dev/null
}

# ^ invariant prints the Windows spelling of a path; the real cygpath on Windows, the stand-in elsewhere
wu_w() { cygpath -w "$1"; }

assert_not_exists_any() {
    local p
    for p in "$@"; do
        if [ -e "$p" ]; then fail "unexpected $p"; fi
    done
}

# ^ invariant the env of every module test; sandbox HOME and state dir, the sandbox as System32, stand-ins first on PATH
wu_env() {
    set_env HOME="$WU_DIR/home" XDG_STATE_HOME="$WU_DIR/xdg/state" GSG_GITUP_ROOT="$WU_DIR/root" PATH="$WU_DIR/pathbin:$TEST_BASE_PATH" LOCALAPPDATA="$(wu_w "$WU_DIR/home/AppData/Local")"
}

# ^ invariant wu_begin SCOPE VERSION leaves a Git for Windows VERSION set up for SCOPE (machine or user) in the registry stand-in
WU_DIR="" WU_GIT="" WU_HANDOFF_DIR="" WU_STATE_HANDOFF="" WU_FRONT_DIR="" WU_SHA=""
wu_begin() {
    local scope="$1" ver="$2" app hive sys
    WU_DIR="$SANDBOX/wu"
    wu_sandbox_path "$WU_DIR" || return 1
    rm -rf -- "$WU_DIR" || return 1
    sys="$WU_DIR/root/windows/System32"
    mkdir -p -- "$WU_DIR/home" "$WU_DIR/xdg/state" "$sys" "$WU_DIR/pathbin" || return 1
    EXTRA_ENV=()
    wu_env
    WU_HANDOFF_DIR="$WU_DIR/xdg/state/git-secret-guard/git-upgrade"
    WU_STATE_HANDOFF="$WU_HANDOFF_DIR/handoff.txt"
    WU_FRONT_DIR="$WU_DIR/home/AppData/Local/git-secret-guard"
    if [ "$scope" = machine ]; then
        app='C:\Program Files\Git' hive=hklm WU_GIT="/c/Program Files/Git/cmd/git.exe"
    else
        app='C:\Users\me\AppData\Local\Programs\Git' hive=hkcu WU_GIT="/c/Users/me/AppData/Local/Programs/Git/cmd/git.exe"
    fi
    printf '    Inno Setup: App Path    REG_SZ    %s\n    InstallLocation    REG_SZ    %s\\\n    DisplayVersion    REG_SZ    %s\n    Inno Setup CodeFile: Editor Option    REG_SZ    VIM\n' \
        "$app" "$app" "$ver" >"$WU_DIR/reg.$hive" || return 1
    {
        printf '#!/bin/sh\nWU_DIR=%q\n' "$WU_DIR"
        cat <<'STUB'
printf '%s\n' "$*" >>"$WU_DIR/reg.log"
case "$2" in
    HKLM[\\]*) f="$WU_DIR/reg.hklm" ;;
    HKCU[\\]*) f="$WU_DIR/reg.hkcu" ;;
    *) exit 2 ;;
esac
if [ ! -f "$f" ]; then echo 'ERROR: The system was unable to find the specified registry key or value.' >&2; exit 1; fi
printf '\r\n%s\r\n' "$2"
sed 's/$/\r/' "$f"
STUB
    } >"$sys/reg.exe" || return 1
    {
        printf '#!/bin/sh\nWU_DIR=%q\n' "$WU_DIR"
        cat <<'STUB'
printf '%s\n' "$*" >>"$WU_DIR/whoami.log"
printf 'GROUP INFORMATION\r\nEveryone   Well-known group S-1-1-0   Mandatory group\r\n'
if [ -f "$WU_DIR/elevated" ]; then printf 'Mandatory Label/High Mandatory Level   Label   S-1-16-12288\r\n'; else printf 'Mandatory Label/Medium Mandatory Level   Label   S-1-16-8192\r\n'; fi
STUB
    } >"$sys/whoami.exe" || return 1
    chmod 755 "$sys/reg.exe" "$sys/whoami.exe" || return 1
}

wu_elevated() { if [ "$1" = yes ]; then : >"$WU_DIR/elevated"; else rm -f -- "$WU_DIR/elevated"; fi; }

wu_winget() {
    {
        printf '#!/bin/sh\nWU_DIR=%q\n' "$WU_DIR"
        printf 'printf "%%s\\n" "$*" >>"$WU_DIR/winget.log"\n'
    } >"$WU_DIR/pathbin/winget" && chmod 755 "$WU_DIR/pathbin/winget"
}

wu_curl_recorder() {
    {
        printf '#!/bin/sh\nWU_DIR=%q\n' "$WU_DIR"
        printf 'printf "%%s\\n" "$*" >>"$WU_DIR/curl.log"\nexec %q "$@"\n' "$(type -P curl)"
    } >"$WU_DIR/pathbin/curl" && chmod 755 "$WU_DIR/pathbin/curl"
}

# ^ invariant wu_fixture good|tampered writes the installer the pinned download serves and a lock for it; tampered serves bytes the lock does not describe
# ^ invariant the installer is a script recording a run => a test sees whether bash ran it
wu_fixture() {
    local fix sha url
    wu_sandbox_path "$WU_DIR" || return 1
    fix="$WU_DIR/fix"
    mkdir -p -- "$fix" || return 1
    printf '#!/bin/sh\ntouch %q\n' "$WU_DIR/installer.ran" >"$fix/Git-2.56.0.4-64-bit.exe" || return 1
    sha="$(sha256sum -- "$fix/Git-2.56.0.4-64-bit.exe" | cut -d' ' -f1)" || return 1
    WU_SHA="$sha"
    if [ "$1" = tampered ]; then
        printf '# tampered after the lock was written\n' >>"$fix/Git-2.56.0.4-64-bit.exe" || return 1
    fi
    printf '# gsg-signer git-for-windows 2.56.0.4 CN=Fixture Signer\ngit-for-windows 2.56.0.4 windows_amd64 %s\n' "$sha" >"$WU_DIR/fixture.lock" || return 1
    if [ "$TEST_IS_WINDOWS" -eq 1 ]; then url="file:///$(cygpath -m "$fix")"; else url="file://$fix"; fi
    set_env GSG_TOOLS_BASE_URL="$url" GSG_TOOLS_LOCK="$WU_DIR/fixture.lock"
}

wu_field() { awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$WU_HANDOFF_DIR/handoff.txt"; }

# ^ external the stand-in installer is a real console .exe compiled by Windows PowerShell (csc); a script cannot be started by Start-Process
# ^ invariant it appends its arguments to $GSG_STANDIN_DIR/installer.log, copies the pair in copy.txt (source|target) when present and exits with exit.txt
WU_STANDIN_SRC='using System; using System.IO;
public static class Standin {
    public static int Main(string[] a) {
        string d = Environment.GetEnvironmentVariable("GSG_STANDIN_DIR");
        File.AppendAllText(Path.Combine(d, "installer.log"), string.Join(" ", a) + "\r\n");
        string copy = Path.Combine(d, "copy.txt");
        if (File.Exists(copy)) { string[] p = File.ReadAllText(copy).Trim().Split((char)124); File.Copy(p[0], p[1], true); }
        string rc = Path.Combine(d, "exit.txt");
        return File.Exists(rc) ? int.Parse(File.ReadAllText(rc).Trim()) : 0;
    }
}'

# ^ invariant skips the test unless this is a Windows host with an elevated prompt; a machine-wide run from a normal prompt would show a UAC prompt
wu_need_windows_runner() {
    if [ "$TEST_IS_WINDOWS" -ne 1 ]; then skip_test "runs bin/gsg-gitup.ps1 with Windows PowerShell"; fi
    if ! "$TEST_SYSTEM32/fltmc.exe" >/dev/null 2>&1; then skip_test "this prompt is not elevated, a machine-wide run would show a UAC prompt"; fi
}

# ^ invariant removes the test signer certificates (subject and issuer equal) from stores My and CA with their keys; nothing else in a store is touched
wu_sweep_signer_certs() {
    GSG_SUBJECT="$WU_SIGNER" "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -Command '
        $ErrorActionPreference = "Stop"
        $s = $env:GSG_SUBJECT
        foreach ($st in "My", "CA") { foreach ($x in @(Get-ChildItem "Cert:\CurrentUser\$st" | Where-Object { $_.Subject -eq $s -and $_.Issuer -eq $s })) { Remove-Item -LiteralPath ("Cert:\CurrentUser\$st\" + $x.Thumbprint) -DeleteKey -Force -ErrorAction Stop } }'
}

# ^ invariant plants one certificate with a key as an aborted build leaves it (stores My and CA, one key file)
wu_plant_signer_cert() {
    GSG_SUBJECT="$WU_SIGNER" "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -Command \
        'New-SelfSignedCertificate -Type CodeSigningCert -Subject $env:GSG_SUBJECT -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10) | Out-Null'
}

# ^ invariant wu_key_files_named NAME prints how many files called NAME the user's CNG key directory holds; NAME comes from wu_build_standin
wu_key_files_named() {
    local count
    [ -n "${1:-}" ] || return 1
    count="$(GSG_KEY="$1" "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -Command '
        $ErrorActionPreference = "Stop"
        @(Get-ChildItem "$env:APPDATA\Microsoft\Crypto\Keys" -Force | Where-Object { $_.Name -eq $env:GSG_KEY }).Count')" || return 1
    printf '%s\n' "${count//$'\r'/}"
}

# ^ invariant the cache directory is named after a hash of the stand-in source => a changed source never uses an old binary
wu_standin_cache() {
    local h
    h="$(printf '%s' "$WU_STANDIN_SRC" | sha256sum | cut -c1-12)" || return 1
    printf '%s/gsg-test-standin-%s\n' "$TEST_TOOLS_CACHE" "$h"
}

# ^ invariant the signed and the unsigned stand-in installer are built once into the tools cache; a test run never creates a certificate when they exist
# ^ external the certificate is self-signed, valid ten years, made in the user store My for signing only; its key and its copy in store CA go on every path
# ^ security the sweep removes only certificates whose subject and issuer both equal the test subject, never anything else in a store
WU_SIGNER="CN=GSG Test Signer"
wu_build_standin() {
    local cache out="$SANDBOX/standin" ps="$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe"
    cache="$(wu_standin_cache)" || return 1
    mkdir -p -- "$out" "$cache" || return 1
    if [ ! -f "$cache/standin.exe" ] || [ ! -f "$cache/standin-unsigned.exe" ]; then
        printf '%s\n' "$WU_STANDIN_SRC" >"$out/standin.cs" || return 1
        GSG_SRC="$(cygpath -w "$out/standin.cs")" GSG_OUT="$(cygpath -w "$out/standin-unsigned.exe")" "$ps" -NoProfile -Command \
            'Add-Type -TypeDefinition (Get-Content -Raw -LiteralPath $env:GSG_SRC) -OutputAssembly $env:GSG_OUT -OutputType ConsoleApplication' >"$out/build.log" 2>&1 || {
            cat "$out/build.log" >&2
            return 1
        }
        cp -- "$out/standin-unsigned.exe" "$out/standin.exe" || return 1
        wu_sweep_signer_certs >>"$out/build.log" 2>&1 || {
            cat "$out/build.log" >&2
            return 1
        }
        # ^ why the key file name is recorded, not the files of the Keys directory counted; every process of the user writes there
        GSG_KEYLOG="$(cygpath -w "$out/key.name")" GSG_OUT="$(cygpath -w "$out/standin.exe")" GSG_SUBJECT="$WU_SIGNER" "$ps" -NoProfile -Command '
            $s = $env:GSG_SUBJECT
            $c = New-SelfSignedCertificate -Type CodeSigningCert -Subject $s -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(10)
            try {
                $k = [System.Security.Cryptography.X509Certificates.RSACertificateExtensions]::GetRSAPrivateKey($c)
                if ($null -eq $k.Key) { throw "the test signer key is not a CNG key" }
                [IO.File]::WriteAllText($env:GSG_KEYLOG, [string]$k.Key.UniqueName)
                Set-AuthenticodeSignature -FilePath $env:GSG_OUT -Certificate $c | Out-Null
            }
            finally {
                foreach ($st in "My", "CA") { $p = "Cert:\CurrentUser\$st\$($c.Thumbprint)"; if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -DeleteKey -Force } }
            }' >>"$out/build.log" 2>&1 || {
            cat "$out/build.log" >&2
            return 1
        }
        cp -- "$out/standin-unsigned.exe" "$cache/standin-unsigned.exe" && cp -- "$out/standin.exe" "$cache/standin.exe" || return 1
    fi
    cp -- "$cache/standin.exe" "$cache/standin-unsigned.exe" "$out/" || return 1
}

# ^ invariant wu_write_lock SHA [SIGNER] writes the lock of the sandbox copy of the product; the pin row and the signer line the runner reads
WU_RT="" WU_LOCK=""
wu_write_lock() {
    printf '# gsg-signer git-for-windows 2.56.0.4 %s\ngit-for-windows 2.56.0.4 windows_amd64 %s\n' "${2:-$WU_SIGNER}" "$1" >"$WU_LOCK"
}

# ^ invariant is wu_fixture good with the signed stand-in as the pinned download and a sandbox copy of the runner with its own tools.lock beside bin
# ^ why a copy with one changed line, not an environment variable; the product runner reads no environment, a test cannot reach its checks from outside
wu_fixture_exe() {
    local fix sha url
    wu_sandbox_path "$WU_DIR" || return 1
    fix="$WU_DIR/fix"
    wu_build_standin || return 1
    WU_RT="$WU_DIR/rt" WU_LOCK="$WU_DIR/rt/tools.lock"
    mkdir -p -- "$fix" "$WU_DIR/standin" "$WU_RT/bin" || return 1
    cp -- "$SANDBOX/standin/standin.exe" "$fix/Git-2.56.0.4-64-bit.exe" || return 1
    sha="$(sha256sum -- "$fix/Git-2.56.0.4-64-bit.exe" | cut -d' ' -f1)" || return 1
    WU_SHA="$sha"
    wu_write_lock "$sha" || return 1
    cp -- "$GSG_PROJECT/bin/gsg-gitup.ps1" "$WU_RT/bin/gsg-gitup.ps1" || return 1
    wu_runner_installed 2.52.0.1 || return 1
    url="file:///$(cygpath -m "$fix")"
    set_env GSG_TOOLS_BASE_URL="$url" GSG_TOOLS_LOCK="$WU_LOCK" GSG_STANDIN_DIR="$(cygpath -w "$WU_DIR/standin")"
}

# ^ invariant changes the sandbox copy of the runner at PATTERN and fails unless exactly one line differs more from the product than before
wu_runner_seam() {
    local before after
    before="$(diff "$GSG_PROJECT/bin/gsg-gitup.ps1" "$WU_RT/bin/gsg-gitup.ps1" | grep -c '^[<>]')"
    sed -i "s/$1/$2/" "$WU_RT/bin/gsg-gitup.ps1" || return 1
    after="$(diff "$GSG_PROJECT/bin/gsg-gitup.ps1" "$WU_RT/bin/gsg-gitup.ps1" | grep -c '^[<>]')"
    [ "$((after - before))" -eq 2 ] || { fail "the seam [$1] must change exactly one line"; return 1; }
}

# ^ invariant sets what the sandbox copy of the runner reports as the installed Git for Windows ('' for none); the copy is made again from the product first
# ^ invariant the status seam is applied again; an elevation seam, if a test wants one, comes after this call
wu_runner_installed() {
    cp -- "$GSG_PROJECT/bin/gsg-gitup.ps1" "$WU_RT/bin/gsg-gitup.ps1" || return 1
    wu_runner_seam "^\$AcceptStatus = 'Valid'\$" "\$AcceptStatus = 'UnknownError'" || return 1
    wu_runner_seam "^function Get-InstalledDir.*" "function Get-InstalledDir([string]\$Scope) { return '' }" || return 1
    wu_runner_seam "^function Get-InstalledVersion.*" "function Get-InstalledVersion([string]\$Scope) { return '$1' }"
}

# ^ invariant the elevation seam replaces the one-line function Test-Elevated; the status seam of wu_fixture_exe stays in the copy
wu_runner_elevation() {
    wu_runner_seam "^function Test-Elevated .*" "function Test-Elevated { return \$$1 }"
}

# ^ invariant wu_runner HANDOFF runs the sandbox copy of bin/gsg-gitup.ps1 in Windows PowerShell; OUT and ERR hold both streams
wu_runner() {
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass \
        -File "$(cygpath -w "${WU_RUNNER:-$WU_RT/bin/gsg-gitup.ps1}")" "$(cygpath -w "$1")"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}

# ^ invariant writes the wrapper script of the shadow run; its Start-Process records the verb, can hold before the start, and fails or skips as MODE says
# ^ why a wrapper function, not a change of the runner; the runner calls Start-Process by name, a function with its name in the caller takes its place
wu_shadow_script() {
    cat >"$WU_DIR/shadow.ps1" <<'SHADOW'
param([string]$Mode)
function Start-Process {
    [CmdletBinding()] param($FilePath, $ArgumentList, $Verb, [switch]$Wait, [switch]$PassThru, [switch]$NoNewWindow)
    Add-Content -LiteralPath $env:GSG_TEST_VERBLOG -Value ('verb=' + $Verb)
    Add-Content -LiteralPath $env:GSG_TEST_VERBLOG -Value ('file=' + $FilePath + ' args=' + ($ArgumentList -join ' '))
    if ($env:GSG_TEST_HOLD) {
        New-Item -ItemType File -Path ($env:GSG_TEST_HOLD + '.held') -Force | Out-Null
        for ($i = 0; $i -lt 600 -and -not (Test-Path -LiteralPath ($env:GSG_TEST_HOLD + '.go')); $i++) { Start-Sleep -Milliseconds 100 }
    }
    if ($Mode -eq 'decline') { throw (New-Object System.ComponentModel.Win32Exception 1223) }
    if ($Mode -eq 'wrapped') { throw (New-Object System.InvalidOperationException 'wrapped', (New-Object System.ComponentModel.Win32Exception 1223)) }
    if ($Mode -eq 'other') { throw (New-Object System.ComponentModel.Win32Exception 193) }
    if ($Mode -eq 'norun') { return [pscustomobject]@{ ExitCode = 0 } }
    if ($Mode -ne 'ok') { throw ('unknown shadow mode ' + $Mode) }
    if ($env:GSG_TEST_NEVER_START -eq '1') { throw 'a test that must never start the installer asked for a real start' }
    $a = @{ FilePath = $FilePath; Wait = $true; PassThru = $true }
    if ($ArgumentList) { $a['ArgumentList'] = $ArgumentList }
    if ($Verb) { $a['Verb'] = $Verb }
    if ($NoNewWindow) { $a['NoNewWindow'] = $true }
    Microsoft.PowerShell.Management\Start-Process @a
}
& $env:GSG_TEST_RUNNER $env:GSG_TEST_HANDOFF
exit $LASTEXITCODE
SHADOW
}

# ^ invariant true only when the runner starts programs through the two Start-Process calls and no other way; the shadow wrapper stands in for those two
# ^ security the test of the real asset checks this before it runs; a new start path (qualified cmdlet, Process class, call operator) fails it
wu_runner_starts_only_through_the_shadowed_calls() {
    local f="$1"
    [ "$(grep -c 'Start-Process' "$f")" -eq 2 ] || return 1
    [ "$(grep -c 'Start-Process @params' "$f")" -eq 1 ] || return 1
    [ "$(grep -c 'Start-Process -FilePath \$w.Source' "$f")" -eq 1 ] || return 1
    if grep -qiE 'Management.Start-Process|Diagnostics.Process|Invoke-Item|Invoke-Expression|Invoke-Command|ShellExecute|WScript|Invoke-WmiMethod|Invoke-CimMethod|cmd(.exe)? /c|&[[:space:]]*[$"'"'"']|\biex\b' "$f"; then return 1; fi
    return 0
}

# ^ invariant runs the runner (WU_RUNNER or the sandbox copy) under the shadow wrapper in MODE (ok, norun, decline, wrapped, other); WU_NEVER_START=1 refuses ok
wu_runner_shadow() {
    local mode="$1"
    if [ "${WU_NEVER_START:-0}" = 1 ] && [ "$mode" = ok ]; then
        fail "a test that must never start the installer asked for the real start"
        return 1
    fi
    wu_shadow_script
    rm -f -- "$WU_DIR/verbs.log"
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GSG_TEST_NEVER_START="${WU_NEVER_START:-0}" GSG_TEST_VERBLOG="$(cygpath -w "$WU_DIR/verbs.log")" GSG_TEST_RUNNER="$(cygpath -w "${WU_RUNNER:-$WU_RT/bin/gsg-gitup.ps1}")" \
        GSG_TEST_HANDOFF="$(cygpath -w "$2")" "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$WU_DIR/shadow.ps1")" "$mode"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}

# ^ invariant runs the runner under a broken wrapper (the cmdlet name is misspelled); the runner reaches the real cmdlet; for a stand-in installer only
wu_runner_broken() {
    cat >"$WU_DIR/shadow-broken.ps1" <<'SHADOW'
function Start-Proces { param($FilePath) throw 'never called' }
& $env:GSG_TEST_RUNNER $env:GSG_TEST_HANDOFF
exit $LASTEXITCODE
SHADOW
    run_cap env -i "${GSG_ENV[@]}" "${EXTRA_ENV[@]}" GSG_TEST_RUNNER="$(cygpath -w "$WU_RT/bin/gsg-gitup.ps1")" GSG_TEST_HANDOFF="$(cygpath -w "$1")" \
        "$TEST_SYSTEM32/WindowsPowerShell/v1.0/powershell.exe" -NoProfile -ExecutionPolicy Bypass -File "$(cygpath -w "$WU_DIR/shadow-broken.ps1")"
    OUT="$(<"$SANDBOX/.out")"
    ERR="$(<"$SANDBOX/.err")"
}

# ^ security execute denied to Everyone (S-1-1-0) on a copy lets the file be read, hashed and checked and not started, whatever the wrapper does
# ^ invariant the path must exist below the sandbox and name a file, never a directory => the deny cannot reach anything else
wu_deny_execute() {
    local f="$1"
    if [ -z "$f" ] || [ "${f#"$SANDBOX"/}" = "$f" ] || [ ! -f "$f" ]; then
        fail "wu_deny_execute wants an existing file below the sandbox, got [$f]"
        return 1
    fi
    MSYS2_ARG_CONV_EXCL='*' "$TEST_SYSTEM32/icacls.exe" "$(cygpath -w "$f")" /deny '*S-1-1-0:(X)' >/dev/null
}

wu_allow_execute() {
    local f="$1"
    if [ -n "$f" ] && [ "${f#"$SANDBOX"/}" != "$f" ] && [ -f "$f" ]; then
        MSYS2_ARG_CONV_EXCL='*' "$TEST_SYSTEM32/icacls.exe" "$(cygpath -w "$f")" /remove:d '*S-1-1-0' >/dev/null
    fi
}

wu_verbs() { if [ -f "$WU_DIR/verbs.log" ]; then grep '^verb=' "$WU_DIR/verbs.log" | tr -d '\r'; fi; }

wu_installer_log() { if [ -f "$WU_DIR/standin/installer.log" ]; then tr -d '\r' <"$WU_DIR/standin/installer.log"; fi; }

# ^ invariant leaves a verified hand-off made by the module itself (plan, apply) for SCOPE and the stand-in installer
wu_prepare_handoff() {
    wu_begin "$1" 2.52.0.1 || return 1
    wu_fixture_exe || return 1
    wu_elevated no
    wu 'gitup_select; GSG_GIT="$1"; gitup_windows_plan upgrade >/dev/null; gitup_windows_apply; echo "rc=$?"' "$WU_GIT"
    assert_contains "$OUT" "rc=2" "the module handed off"
}

# ^ invariant the sorted names in a directory on one line; the stray-file check compares two of these
wu_names() {
    local f
    for f in "$1"/* "$1"/.[!.]* "$1"/..?*; do
        if [ -e "$f" ] || [ -L "$f" ]; then printf '%s\n' "${f##*/}"; fi
    done | LC_ALL=C sort | tr '\n' ' '
}

# ^ why a read loop, not sed; a Windows path in a sed replacement turns \r, \U or \a (from \runneradmin, \Users) into control characters and breaks the hand-off
# ^ invariant wu_rewrite_installer SRC OUT WINPATH copies a hand-off with its installer line replaced by WINPATH, byte for byte otherwise
wu_rewrite_installer() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            installer=*) printf 'installer=%s\n' "$3" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done <"$1" >"$2"
}
