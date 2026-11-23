# ^ external powershell -NoProfile -ExecutionPolicy Bypass -File gsg-path.ps1 VERB ARGS puts the CLI folder on the user Path and takes it off again
# ^ invariant VERB plan FOLDER, apply MODE FOLDER, remove MODE FOLDER; MODE is sep (append ;FOLDER), bare (FOLDER after a final ;) or create (no value yet)
# ^ invariant only the value Path of HKCU\Environment, never the machine Path, no administrator rights, never setx (it cuts a value at 1024 characters)

# ^ security no byte of the value is printed; stdout is one ASCII status word, a failure is a non-zero exit and one line on stderr, bash reads nothing else
# ^ invariant exit 0 done (status word printed); 1 unexpected error; 2 refused (arguments, registry type, length); 3 the value no longer fits the plan
# ^ invariant status words are plan present, absent-sep, absent-bare, absent-novalue; apply added; remove removed, changed, absent; -nobroadcast after a write

# ^ invariant no cmdlet is used, the module path of a PowerShell 7 parent cannot matter; the registry is reached through .NET only
param([string]$Verb, [string]$First, [string]$Second)
Set-StrictMode -Version 2
$ErrorActionPreference = 'Stop'
# ^ external Windows accepts less than 32,767 characters for one environment variable (the limit counts the closing NUL); a longer new value is refused, not cut
$MaxChars = 32767
$Kinds = 'String', 'ExpandString'
$CreateKind = 'ExpandString'
$FolderPattern = '^([A-Za-z]:\\|\\\\[^\\])[^;%"\x00-\x1f]*$'

function Stop-Run([int]$Code, [string]$Text) {
    [Console]::Error.WriteLine($Text)
    exit $Code
}

function Say([string]$Word) { [Console]::Out.WriteLine($Word) }

# ^ invariant returns $null when the user has no Path value, else @{ Value; Kind } with the value as stored (%VARS% not expanded); tests replace this one line
function Get-UserPath { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $false); try { if ($k.GetValueNames() -notcontains 'Path') { return $null }; return @{ Value = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames); Kind = $k.GetValueKind('Path').ToString() } } finally { $k.Close() } }

# ^ invariant writes the value Path of the user with the registry type Kind (String or ExpandString); tests replace this one line
function Set-UserPath([string]$Value, [string]$Kind) { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true); try { $k.SetValue('Path', $Value, [Microsoft.Win32.RegistryValueKind]$Kind) } finally { $k.Close() } }

# ^ invariant deletes the value Path of the user; tests replace this one line
function Remove-UserPath { $k = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true); try { $k.DeleteValue('Path', $true) } finally { $k.Close() } }

# ^ external a user variable set and deleted through .NET sends WM_SETTINGCHANGE to every window, the registry write alone tells no running program
# ^ why a throwaway variable, not SendMessageTimeout through Add-Type; no compiler run, no native signature to get wrong, works under constrained language
# ^ see Microsoft Learn Environment.SetEnvironmentVariable for the broadcast; tests replace this one line
function Send-EnvironmentChange { [Environment]::SetEnvironmentVariable('GSG_ENV_CHANGED', '1', 'User'); [Environment]::SetEnvironmentVariable('GSG_ENV_CHANGED', $null, 'User') }

# ^ invariant the word printed after a write; a failed broadcast never undoes or fails a written value, it only changes the word
function Send-AndSay([string]$Word) {
    try { Send-EnvironmentChange } catch { Say "$Word-nobroadcast"; return }
    Say $Word
}

# ^ invariant two entries are the same folder when they differ only by case, slash direction, trailing slashes or a %VARIABLE%, expanded for the comparison only
function Test-SameFolder([string]$Entry, [string]$Folder) {
    if ($Entry -eq '') { return $false }
    $a = [Environment]::ExpandEnvironmentVariables($Entry).Replace('/', '\').TrimEnd('\').ToUpperInvariant()
    $b = [Environment]::ExpandEnvironmentVariables($Folder).Replace('/', '\').TrimEnd('\').ToUpperInvariant()
    return ($a -ceq $b)
}

function Test-Holds([string]$Value, [string]$Folder) {
    foreach ($e in $Value.Split(';')) { if (Test-SameFolder $e $Folder) { return $true } }
    return $false
}

function Assert-Writable($Current, [string]$NewValue) {
    if ($Kinds -notcontains $Current.Kind) { Stop-Run 2 "the user Path has the registry type $($Current.Kind), which this tool does not change" }
    if ($NewValue.Length -ge $MaxChars) { Stop-Run 2 "the user Path would reach $($NewValue.Length) characters, more than Windows accepts for one variable" }
}

# ^ invariant the value with the folder appended for MODE, or $null when the value no longer ends the way the plan saw it
# ^ invariant sep needs a value without a final ; and bare needs a final ; or an empty value
function Get-Appended([string]$Value, [string]$Mode, [string]$Folder) {
    if ($Mode -eq 'sep' -and $Value -ne '' -and -not $Value.EndsWith(';')) { return $Value + ';' + $Folder }
    if ($Mode -eq 'bare' -and ($Value -eq '' -or $Value.EndsWith(';'))) { return $Value + $Folder }
    return $null
}

function Invoke-Plan([string]$Folder) {
    $cur = Get-UserPath
    if ($null -eq $cur) { Assert-Writable @{ Kind = $CreateKind } $Folder; Say 'absent-novalue'; return }
    if (Test-Holds $cur.Value $Folder) { Say 'present'; return }
    $mode = 'sep'
    if ($cur.Value -eq '' -or $cur.Value.EndsWith(';')) { $mode = 'bare' }
    Assert-Writable $cur (Get-Appended $cur.Value $mode $Folder)
    Say "absent-$mode"
}

function Invoke-Apply([string]$Mode, [string]$Folder) {
    $cur = Get-UserPath
    if ($Mode -eq 'create') {
        if ($null -ne $cur) { Stop-Run 3 'the user Path was created while install ran; nothing was changed' }
        Assert-Writable @{ Kind = $CreateKind } $Folder
        Set-UserPath $Folder $CreateKind
        Send-AndSay 'added'
        return
    }
    if ($null -eq $cur) { Stop-Run 3 'the user Path was deleted while install ran; nothing was changed' }
    if (Test-Holds $cur.Value $Folder) { Stop-Run 3 'the user Path holds the folder already; nothing was changed' }
    $new = Get-Appended $cur.Value $Mode $Folder
    if ($null -eq $new) { Stop-Run 3 'the user Path changed while install ran; nothing was changed' }
    Assert-Writable $cur $new
    Set-UserPath $new $cur.Kind
    Send-AndSay 'added'
}

# ^ invariant the value install wrote ends with the recorded text, or has one element equal to the folder byte for byte; another spelling is only named
# ^ invariant what is cut is the text, or the element with exactly one adjacent separator; every other byte of the value stays, and the registry type too
function Get-Remainder([string]$Value, [string]$Mode, [string]$Folder) {
    $text = $Folder
    if ($Mode -eq 'sep') { $text = ';' + $Folder }
    if ($Value.EndsWith($text, [StringComparison]::Ordinal)) {
        $head = $Value.Substring(0, $Value.Length - $text.Length)
        if ($Mode -eq 'sep' -or ($Mode -eq 'bare' -and ($head -eq '' -or $head.EndsWith(';'))) -or ($Mode -eq 'create' -and $head -eq '')) { return $head }
    }
    $parts = $Value.Split(';')
    for ($i = $parts.Length - 1; $i -ge 0; $i--) {
        if ($parts[$i] -ceq $Folder) {
            $keep = [System.Collections.Generic.List[string]]::new()
            for ($j = 0; $j -lt $parts.Length; $j++) { if ($j -ne $i) { $keep.Add($parts[$j]) } }
            return [string]::Join(';', $keep.ToArray())
        }
    }
    return $null
}

function Invoke-Remove([string]$Mode, [string]$Folder) {
    $cur = Get-UserPath
    if ($null -eq $cur) { Say 'absent'; return }
    $rest = Get-Remainder $cur.Value $Mode $Folder
    if ($null -eq $rest) {
        if (Test-Holds $cur.Value $Folder) { Say 'changed' } else { Say 'absent' }
        return
    }
    if ($Kinds -notcontains $cur.Kind) { Stop-Run 2 "the user Path has the registry type $($cur.Kind), which this tool does not change" }
    if ($rest -eq '' -and $Mode -eq 'create') { Remove-UserPath } else { Set-UserPath $rest $cur.Kind }
    Send-AndSay 'removed'
}

try {
    if ($Verb -notin 'plan', 'apply', 'remove') { Stop-Run 2 'usage: gsg-path.ps1 plan FOLDER | apply MODE FOLDER | remove MODE FOLDER' }
    if ($Verb -eq 'plan') { $mode = 'sep'; $folder = $First } else { $mode = $First; $folder = $Second }
    if ($mode -notin 'sep', 'bare', 'create') { Stop-Run 2 'the form is not sep, bare or create' }
    if ($folder -cnotmatch $FolderPattern) { Stop-Run 2 'the folder is not an absolute Windows path without ; % " or control characters' }
    switch ($Verb) {
        'plan' { Invoke-Plan $folder }
        'apply' { Invoke-Apply $mode $folder }
        'remove' { Invoke-Remove $mode $folder }
    }
} catch {
    Stop-Run 1 "unexpected error: $((($_.Exception.Message) -replace '\s+', ' ').Trim())"
}
exit 0
