#Requires -Version 5.1
<#
.SYNOPSIS
    shrink-unlock - find what stops Windows from shrinking a drive, turn it
    off, shrink the drive, then turn everything back on.

.DESCRIPTION
    Disk Management can only shrink a drive up to the last file it cannot
    move. So a drive with 45 GB free can still be limited to a few MB. On the
    Windows drive the usual blockers are the page file, the hibernation file,
    the memory dump and restore points (shadow copies).

    The script is a small menu:

      1  Check     how much the drive can shrink now, what is in the way and
                   which file is the last unmovable one
      2  Unlock    saves your current settings, then turns off hibernation,
                   the page file, the memory dump and System Restore for the
                   drive, deletes its shadow copies and restarts Windows.
                   After the restart the script opens again by itself.
      3  Shrink    consolidates free space (defrag /X), shows the new limit
                   and shrinks by the amount you choose
      4  Restore   turns every saved setting back on

    Nothing is changed until you type YES. Settings are saved to
    %ProgramData%\shrink-unlock\state.json before anything is turned off, so
    Restore still works after a crash or a restart.

    Deleted restore points cannot be brought back. Restore only turns
    System Restore on again.

.PARAMETER Drive
    Drive letter to shrink. If omitted you are asked (default: the Windows
    drive).

.PARAMETER Resume
    Used after the restart: goes straight to Shrink.

.PARAMETER Restore
    Turn the saved settings back on and exit.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\shrink-unlock.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\shrink-unlock.ps1 -Drive C -Restore
#>
[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z]:?$')]
    [string]$Drive,
    [switch]$Resume,
    [switch]$Restore
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------- elevation --
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host 'Administrator rights are needed. Asking Windows to elevate...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        $v = $PSBoundParameters[$k]
        if ($v -is [switch]) {
            if ($v) { $argList += ('-' + $k) }
        } else {
            $argList += ('-' + $k)
            $argList += ('"{0}"' -f $v)
        }
    }
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    exit
}

# ---------------------------------------------------------------- constants --
$ScriptPath   = $PSCommandPath
$StateDir     = Join-Path $env:ProgramData 'shrink-unlock'
$StateFile    = Join-Path $StateDir 'state.json'
$RunOnceKey   = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'
$RunOnceName  = 'shrink-unlock'
$CrashKey     = 'HKLM:\SYSTEM\CurrentControlSet\Control\CrashControl'
$PowerKey     = 'HKLM:\SYSTEM\CurrentControlSet\Control\Power'
$SystemLetter = $env:SystemDrive.Substring(0, 1).ToUpper()
$AdminsSid    = 'S-1-5-32-544'
$SystemSid    = 'S-1-5-18'

# ------------------------------------------------------------------ helpers --
function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Step([string]$Text) { Write-Host ''; Write-Host ('==> ' + $Text) -ForegroundColor Cyan }

function Confirm-Yes([string]$Prompt) {
    $a = Read-Host ($Prompt + ' Type YES to continue')
    return ($a -ceq 'YES')
}

function Confirm-YN([string]$Prompt) {
    $a = Read-Host ($Prompt + ' [y/N]')
    return ($a -match '^(y|yes)$')
}

function Format-GB([double]$Bytes) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }

function Get-VolumePath([string]$L) { return (Get-Volume -DriveLetter $L).Path }

function Get-ShrinkInfo([string]$L) {
    $p = Get-Partition -DriveLetter $L
    $v = Get-Volume -DriveLetter $L
    $s = Get-PartitionSupportedSize -DriveLetter $L
    $size = [int64]$p.Size
    $min = [int64]$s.SizeMin
    return [pscustomobject]@{
        Size      = $size
        Free      = [int64]$v.SizeRemaining
        MinSize   = $min
        MaxShrink = [int64]([math]::Max(0, $size - $min))
    }
}

function Test-HibernateOn {
    try {
        $h = (Get-ItemProperty -Path $PowerKey -Name HibernateEnabled -ErrorAction Stop).HibernateEnabled
        return ([int]$h -eq 1)
    } catch {
        return (Test-Path -LiteralPath ($env:SystemDrive + '\hiberfil.sys'))
    }
}

function Get-CrashDumpSetting {
    try { return [int](Get-ItemProperty -Path $CrashKey -Name CrashDumpEnabled -ErrorAction Stop).CrashDumpEnabled }
    catch { return 0 }
}

function Get-PagefileOnDrive([string]$L) {
    return @(Get-CimInstance Win32_PageFileUsage | Where-Object { $_.Name -like ($L + ':\*') })
}

function Get-PagefileSettingOnDrive([string]$L) {
    return @(Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -like ($L + ':\*') })
}

function Get-ShadowCount([string]$L) {
    try {
        $vp = Get-VolumePath $L
        return @(Get-CimInstance Win32_ShadowCopy | Where-Object { $_.VolumeName -eq $vp }).Count
    } catch { return 0 }
}

function Test-ShadowStorage([string]$L) {
    try {
        $vp = Get-VolumePath $L
        foreach ($ss in @(Get-CimInstance Win32_ShadowStorage)) {
            if ($ss.Volume.DeviceID -eq $vp) { return $true }
        }
    } catch { Write-Verbose ('Shadow storage query failed: ' + $_.Exception.Message) }
    return $false
}

function Get-Blocker([string]$L) {
    $list = @()
    $isSys = ($L -eq $SystemLetter)
    if ($isSys -and (Test-HibernateOn)) { $list += 'Hibernation file (hiberfil.sys)' }
    $pf = Get-PagefileOnDrive $L
    if ($pf.Count -gt 0) { $list += ('Page file (' + (($pf | ForEach-Object { $_.Name }) -join ', ') + ')') }
    if ($isSys -and (Get-CrashDumpSetting) -ne 0) { $list += 'Memory dump is on (MEMORY.DMP)' }
    $sc = Get-ShadowCount $L
    if ($sc -gt 0) { $list += ([string]$sc + ' restore point(s) or shadow copies') }
    elseif (Test-ShadowStorage $L) { $list += 'System Restore is on for this drive' }
    return $list
}

function Show-LastUnmovable([string]$L, [datetime]$Since) {
    $events = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 259; StartTime = $Since } -MaxEvents 20 -ErrorAction Stop)
    } catch { $events = @() }
    if ($events.Count -eq 0) {
        Say 'Windows did not log which file is the last unmovable one (event 259).' DarkGray
        return
    }
    $ev = $events | Where-Object { $_.Message -match ('\(' + $L + ':\)') } | Select-Object -First 1
    if ($null -eq $ev) { $ev = $events[0] }

    $file = $null
    if ($ev.Message -match 'unmovable file appears to be:\s*(\S.*)') { $file = $Matches[1].Trim() }
    if ($null -eq $file) {
        Say 'Last shrink analysis from Windows:' Yellow
        Say $ev.Message
        return
    }
    Say ('Last unmovable file: ' + $file) Yellow
    if ($file -match 'pagefile|hiberfil|swapfile|MEMORY\.DMP|System Volume Information') {
        Say 'Unlock (menu 2) takes care of this one.'
    } elseif ($file -match '\$(MFT|LogFile|Extend|BadClus|Secure|UpCase|Bitmap|Boot|Volume|AttrDef|TxfLog)') {
        Say 'This is NTFS metadata. Windows cannot move it while it is running.'
        Say 'If you need more room than this, use an offline partition tool booted from USB (for example GParted Live).'
    } else {
        Say 'This is a normal file that something keeps locked. Close the program that uses it, or try again after a restart.'
    }
}

# -------------------------------------------------------------------- state --
function Protect-StateDir {
    if (-not (Test-Path -LiteralPath $StateDir)) { New-Item -ItemType Directory -Path $StateDir -Force | Out-Null }
    & icacls.exe $StateDir /reset /T /C /Q | Out-Null
    & icacls.exe $StateDir /inheritance:r /grant:r ('*' + $AdminsSid + ':(OI)(CI)F') ('*' + $SystemSid + ':(OI)(CI)F') /Q | Out-Null
    & icacls.exe $StateDir /setowner ('*' + $AdminsSid) /T /C /Q | Out-Null
}

function Save-State($State) {
    Protect-StateDir
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8
    & icacls.exe $StateFile /setowner ('*' + $AdminsSid) /C /Q | Out-Null
}

function Read-State {
    if (-not (Test-Path -LiteralPath $StateFile)) { return $null }
    $owner = (Get-Acl -LiteralPath $StateFile).GetOwner([Security.Principal.SecurityIdentifier]).Value
    if (@($AdminsSid, $SystemSid) -notcontains $owner) {
        throw ('The saved settings file is owned by ' + $owner + ', not Administrators. Refusing to use it: ' + $StateFile)
    }
    $s = Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json
    if ([string]$s.Drive -notmatch '^[A-Z]$') { throw 'The saved settings file is damaged (drive letter).' }
    foreach ($p in @($s.Pagefiles)) {
        if ($null -eq $p) { continue }
        if ([string]$p.Name -notmatch '^[A-Za-z]:\\pagefile\.sys$') { throw 'The saved settings file is damaged (page file name).' }
    }
    if ($null -ne $s.CrashDump -and ([int]$s.CrashDump -lt 0 -or [int]$s.CrashDump -gt 7)) {
        throw 'The saved settings file is damaged (memory dump value).'
    }
    return $s
}

function Get-StateTime($State) {
    return [datetime]::Parse([string]$State.UnlockedAt, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
}

function Remove-RunOnce {
    try { Remove-ItemProperty -Path $RunOnceKey -Name $RunOnceName -ErrorAction Stop } catch { Write-Verbose 'No RunOnce entry to remove.' }
}

function Request-Restart([string]$Why) {
    if (Confirm-YN ('Restart Windows now? ' + $Why)) {
        Restart-Computer -Force
        exit
    }
    Say 'Restart Windows yourself when ready.' Yellow
}

# ------------------------------------------------------------------ actions --
function Invoke-Check([string]$L) {
    Step ('Checking drive ' + $L + ':')
    $t = (Get-Date).AddSeconds(-2)
    $i = Get-ShrinkInfo $L
    Say ('Size:          ' + (Format-GB $i.Size))
    Say ('Free:          ' + (Format-GB $i.Free))
    Say ('Can shrink by: ' + (Format-GB $i.MaxShrink)) Green
    $b = @(Get-Blocker $L)
    if ($b.Count -eq 0) {
        Say 'No page file, hibernation file, memory dump or restore points on this drive.'
    } else {
        Say 'In the way (Unlock turns these off):' Yellow
        foreach ($x in $b) { Say ('  ' + $x) }
    }
    Show-LastUnmovable $L $t
}

function Invoke-Unlock([string]$L) {
    Step ('Unlock drive ' + $L + ':')
    if (Test-Path -LiteralPath $StateFile) {
        Say 'Settings from an earlier Unlock are still saved. Shrink, then Restore, before unlocking again.' Yellow
        return
    }

    $isSys      = ($L -eq $SystemLetter)
    $cs         = Get-CimInstance Win32_ComputerSystem
    $autoPf     = [bool]$cs.AutomaticManagedPagefile
    $pfSettings = Get-PagefileSettingOnDrive $L
    $pfUse      = Get-PagefileOnDrive $L
    $autoOff    = ($autoPf -and $isSys)
    $pfTouched  = ($pfUse.Count -gt 0) -or ($pfSettings.Count -gt 0) -or $autoOff
    $hib        = ($isSys -and (Test-HibernateOn))
    $crash      = $null
    if ($isSys) { $crash = Get-CrashDumpSetting }
    $crashOff   = ($isSys -and $crash -ne 0)
    $dump       = Join-Path $env:SystemRoot 'MEMORY.DMP'
    $dumpExists = ($isSys -and (Test-Path -LiteralPath $dump))
    $restoreOn  = Test-ShadowStorage $L
    $shadows    = Get-ShadowCount $L

    if (-not ($hib -or $pfTouched -or $crashOff -or $dumpExists -or $restoreOn -or $shadows -gt 0)) {
        Say 'Nothing to turn off on this drive. Go straight to Shrink (menu 3), it runs defrag /X first.'
        return
    }

    Say 'This will:'
    if ($hib)        { Say '  turn off hibernation' }
    if ($pfTouched)  { Say ('  turn off the page file on ' + $L + ':') }
    if ($crashOff)   { Say '  turn off the memory dump' }
    if ($dumpExists) { Say ('  delete ' + $dump) }
    if ($restoreOn)  { Say ('  turn off System Restore for ' + $L + ':') }
    if ($shadows -gt 0) { Say ('  DELETE ' + $shadows + ' restore point(s) on ' + $L + ': (they cannot be brought back)') Yellow }
    Say '  then restart Windows so the page file goes away'
    Say 'Your current settings are saved first, so Restore (menu 4) can turn them back on.'
    if (-not (Confirm-Yes 'Continue?')) { Say 'Cancelled.'; return }

    $state = [ordered]@{
        Version         = 1
        Drive           = $L
        UnlockedAt      = (Get-Date).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        HibernateWasOn  = $hib
        PagefileTouched = $pfTouched
        PagefileAutoOff = $autoOff
        Pagefiles       = @($pfSettings | ForEach-Object { [ordered]@{ Name = [string]$_.Name; InitialSize = [int]$_.InitialSize; MaximumSize = [int]$_.MaximumSize } })
        CrashDump       = $crash
        RestoreWasOn    = $restoreOn
    }
    Save-State $state
    Say ('Settings saved to ' + $StateFile) Green

    if ($hib) {
        Step 'Turning off hibernation'
        & powercfg.exe /h off
        if ($LASTEXITCODE -ne 0) { Say 'powercfg could not turn off hibernation.' Yellow }
    }
    if ($pfTouched) {
        Step 'Turning off the page file'
        if ($autoOff) { $cs | Set-CimInstance -Property @{ AutomaticManagedPagefile = $false } }
        Get-PagefileSettingOnDrive $L | Remove-CimInstance
        if (@(Get-CimInstance Win32_PageFileSetting).Count -eq 0) {
            Say 'Windows will run without a page file until Restore. Avoid very heavy programs until then.' Yellow
        }
    }
    if ($crashOff) {
        Step 'Turning off the memory dump'
        Set-ItemProperty -Path $CrashKey -Name CrashDumpEnabled -Value 0 -Type DWord
    }
    if ($dumpExists) { Remove-Item -LiteralPath $dump -Force }
    if ($restoreOn) {
        Step 'Turning off System Restore'
        try { Disable-ComputerRestore -Drive ($L + ':\') }
        catch { Say ('Could not turn off System Restore: ' + $_.Exception.Message) Yellow }
    }
    if ((Get-ShadowCount $L) -gt 0) {
        Step 'Deleting restore points'
        & vssadmin.exe delete shadows ('/for=' + $L + ':') /all /quiet | Out-Null
    }

    if (-not (Test-Path -LiteralPath $RunOnceKey)) { New-Item -Path $RunOnceKey -Force | Out-Null }
    $cmd = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" -Drive ' + $L + ' -Resume'
    Set-ItemProperty -Path $RunOnceKey -Name $RunOnceName -Value $cmd

    Say ''
    Say 'Unlock done. After the restart this script opens again and continues with Shrink.' Green
    Request-Restart '(needed for the page file to go away)'
}

function Invoke-Shrink([string]$L, $State) {
    Step ('Shrink drive ' + $L + ':')
    if ($null -ne $State -and $State.PagefileTouched) {
        $boot = (Get-CimInstance Win32_OperatingSystem).LastBootUpTime
        if ($boot -lt (Get-StateTime $State)) {
            Say 'Windows has not restarted since Unlock, so the page file is still there.' Yellow
            if (-not (Confirm-YN 'Shrink anyway?')) { return }
        }
    }

    $before = Get-ShrinkInfo $L
    Say ('Can shrink by right now: ' + (Format-GB $before.MaxShrink))
    if (Confirm-YN ('Consolidate free space first (defrag ' + $L + ': /X)? Takes a while, usually frees the most room.')) {
        & defrag.exe ($L + ':') /X /U /V
    }

    $t = (Get-Date).AddSeconds(-2)
    $info = Get-ShrinkInfo $L
    Say ''
    Say ('Size:          ' + (Format-GB $info.Size))
    Say ('Free:          ' + (Format-GB $info.Free))
    Say ('Can shrink by: ' + (Format-GB $info.MaxShrink)) Green
    Show-LastUnmovable $L $t

    $maxGB = [int64][math]::Floor($info.MaxShrink / 1GB)
    if ($maxGB -lt 1) {
        Say 'Less than 1 GB can be freed, so there is nothing to shrink.' Yellow
    } else {
        $gb = 0
        while ($true) {
            $ans = Read-Host ('Shrink by how many GB? (1 to ' + $maxGB + ', Enter to skip)')
            if ([string]::IsNullOrWhiteSpace($ans)) { break }
            $n = 0
            if ([int]::TryParse($ans.Trim(), [ref]$n) -and $n -ge 1 -and $n -le $maxGB) { $gb = $n; break }
            Say ('Enter a whole number from 1 to ' + $maxGB + '.') Yellow
        }
        if ($gb -gt 0) {
            if (Confirm-Yes ('Shrink ' + $L + ': by ' + $gb + ' GB?')) {
                $newSize = $info.Size - ([int64]$gb * 1GB)
                Resize-Partition -DriveLetter $L -Size $newSize
                $after = Get-Partition -DriveLetter $L
                Say ('Done. ' + $L + ': is now ' + (Format-GB $after.Size) + '. The freed space is unallocated, right after the drive.') Green
            } else {
                Say 'Cancelled.'
            }
        }
    }

    if ($null -ne $State) {
        if (Confirm-YN 'Turn your saved settings back on now?') { Invoke-Restore $State }
        else { Say 'Run this script again and choose Restore (menu 4) when you are done.' Yellow }
    }
}

function Invoke-Restore($State) {
    Step 'Turning saved settings back on'
    if ($null -eq $State) { Say 'No saved settings found. Nothing to restore.'; return }
    $L = [string]$State.Drive

    if ($State.HibernateWasOn) {
        & powercfg.exe /h on
        if ($LASTEXITCODE -eq 0) { Say 'Hibernation: on' } else { Say 'Could not turn hibernation back on. Run: powercfg /h on' Yellow }
    }
    if ($State.PagefileTouched) {
        try {
            if ($State.PagefileAutoOff) {
                Get-CimInstance Win32_ComputerSystem | Set-CimInstance -Property @{ AutomaticManagedPagefile = $true }
            } else {
                foreach ($p in @($State.Pagefiles)) {
                    if ($null -eq $p) { continue }
                    $have = @(Get-CimInstance Win32_PageFileSetting | Where-Object { $_.Name -eq $p.Name })
                    if ($have.Count -eq 0) {
                        $new = New-CimInstance -ClassName Win32_PageFileSetting -Property @{ Name = [string]$p.Name }
                        $new | Set-CimInstance -Property @{ InitialSize = [uint32]$p.InitialSize; MaximumSize = [uint32]$p.MaximumSize }
                    }
                }
            }
            Say 'Page file: on (after restart)'
        } catch {
            Say ('Could not turn the page file back on: ' + $_.Exception.Message) Yellow
            Say 'Set it by hand: System Properties > Advanced > Performance > Settings > Advanced > Virtual memory.' Yellow
        }
    }
    if ($null -ne $State.CrashDump) {
        Set-ItemProperty -Path $CrashKey -Name CrashDumpEnabled -Value ([int]$State.CrashDump) -Type DWord
        Say 'Memory dump: back to the saved setting'
    }
    if ($State.RestoreWasOn) {
        try { Enable-ComputerRestore -Drive ($L + ':\'); Say 'System Restore: on' }
        catch { Say ('Could not turn System Restore back on: ' + $_.Exception.Message) Yellow }
    }

    Remove-RunOnce
    Remove-Item -LiteralPath $StateFile -Force
    Say 'All saved settings are back on. Deleted restore points cannot be brought back.' Green
    Request-Restart '(needed for the page file to come back)'
}

# --------------------------------------------------------------------- main --
try {
    $state = Read-State
} catch {
    Say $_.Exception.Message Red
    exit 1
}

if ($null -ne $state) {
    $L = [string]$state.Drive
    if ($Drive -and $Drive.Substring(0, 1).ToUpper() -ne $L) {
        Say ('Settings for drive ' + $L + ': are still saved from an earlier Unlock, so using ' + $L + ':.') Yellow
    }
} elseif ($Drive) {
    $L = $Drive.Substring(0, 1).ToUpper()
} else {
    $a = Read-Host ('Which drive do you want to shrink? (Enter for ' + $SystemLetter + ')')
    if ([string]::IsNullOrWhiteSpace($a)) { $L = $SystemLetter } else { $L = $a.Trim().Substring(0, 1).ToUpper() }
}

try { Get-Partition -DriveLetter $L | Out-Null }
catch { Say ('Drive ' + $L + ': was not found.') Red; exit 1 }

try {
    if ($Restore) { Invoke-Restore $state; exit 0 }
    if ($Resume) {
        Remove-RunOnce
        Say 'Welcome back. Continuing with Shrink.' Green
        Invoke-Shrink $L $state
    }
} catch {
    Say ('Error: ' + $_.Exception.Message) Red
}

while ($true) {
    try { $state = Read-State } catch { Say $_.Exception.Message Red; exit 1 }
    Write-Host ''
    Say ('shrink-unlock   drive ' + $L + ':') Cyan
    if ($null -ne $state) { Say 'Unlock is active: some settings are turned off. Restore when you are done.' Yellow }
    Say '  1  Check     how much can shrink and what is in the way'
    Say '  2  Unlock    turn off the blockers and restart'
    Say '  3  Shrink    consolidate free space and shrink'
    Say '  4  Restore   turn the saved settings back on'
    Say '  Q  Quit'
    $c = Read-Host 'Choose'
    try {
        switch -Regex ($c.Trim()) {
            '^1$'   { Invoke-Check $L }
            '^2$'   { Invoke-Unlock $L }
            '^3$'   { Invoke-Shrink $L $state }
            '^4$'   { Invoke-Restore $state }
            '^[qQ]$' { exit 0 }
            default { Say 'Choose 1, 2, 3, 4 or Q.' Yellow }
        }
    } catch {
        Say ('Error: ' + $_.Exception.Message) Red
    }
}
