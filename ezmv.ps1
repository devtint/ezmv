#Requires -Version 5.1
<#
.SYNOPSIS
    ezmv - move free space from a data drive to the drive on its left
    (typically D: -> C:) with built-in Windows tools only, keeping the files.

.DESCRIPTION
    Windows can only extend a volume into unallocated space directly to its
    right, and it cannot slide a partition sideways. So when the layout is

        C: | Recovery | D:

    Disk Management cannot give part of D: to C:. ezmv shuffles the files
    instead of the partition:

      1. shrink the data drive and create a temporary drive in the freed space
      2. copy the files to the temporary drive and verify the copy
      3. delete the old data drive and any recovery partition in between
      4. extend the target drive
      5. create a new data drive, copy the files back and verify
      6. delete the temporary drive and grow the data drive

    Everything is auto-detected. Nothing is changed until you type YES.
    Progress is saved after every step, so an interrupted run (error, reboot,
    power cut) can be resumed by starting ezmv again.

.PARAMETER Target
    Drive letter that should grow. Default: the Windows drive.

.PARAMETER GiveGB
    How many GB to move. If omitted you are asked.

.PARAMETER PlanOnly
    Detect everything and print the plan, but never change the disk.

.PARAMETER Yes
    Answer every question with yes. For unattended runs and tests.

.PARAMETER VerifyHash
    Also compare the SHA-256 of every file after each copy (slower). Without
    it, the copy is verified by file size and timestamp.

.PARAMETER StatePath
    Where the resume file is kept. Default: %ProgramData%\ezmv\state.json

.PARAMETER StopAfterPhase
    Testing only: stop after the given step (1-9) to simulate an interruption.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\ezmv.ps1 -PlanOnly

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\ezmv.ps1

.LINK
    https://github.com/devtint/ezmv
#>
[CmdletBinding()]
param(
    [string]$Target,
    [int]$GiveGB = 0,
    [switch]$PlanOnly,
    [switch]$Yes,
    [switch]$VerifyHash,
    [string]$StatePath,
    [int]$StopAfterPhase = 0
)

$ErrorActionPreference = 'Stop'
$EzmvVersion = '0.9.1'
$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$TempLabel = 'ezmv-temp'
$SidAdmins = 'S-1-5-32-544'
$SidSystem = 'S-1-5-18'

# Set by the main script (always elevated) so the resume file is written with
# an Administrators-only ACL. Left off when dot-sourced, so the tests run
# without admin rights.
$script:ProtectState = $false
$IsDotSourced = ($MyInvocation.InvocationName -eq '.')

# robocopy flags (the tests override these so they can run without admin rights)
$script:RoboCopyFlags = @('/COPYALL', '/B')
$script:RoboVerifyFlags = @('/B')

# ---------------------------------------------------------------- elevation --
if (-not $IsDotSourced) {
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
}

# ------------------------------------------------------------------ helpers --
function Say([string]$Text, [string]$Color = 'Gray') { Write-Host $Text -ForegroundColor $Color }
function Step([string]$Text) { Write-Host ''; Write-Host ('==> ' + $Text) -ForegroundColor Cyan }
function ToGB($Bytes) { '{0:N2}' -f ([double]$Bytes / 1GB) }
function FloorMB([double]$Bytes) { [int64]([math]::Floor($Bytes / 1MB)) * 1MB }
function CeilMB([double]$Bytes) { [int64]([math]::Ceiling($Bytes / 1MB)) * 1MB }

function Ask-YesNo([string]$Question) {
    if ($Yes) { Say ($Question + ' (y/n): y  [-Yes]'); return $true }
    while ($true) {
        $a = (Read-Host ($Question + ' (y/n)')).Trim().ToLower()
        if ($a -eq 'y' -or $a -eq 'yes') { return $true }
        if ($a -eq 'n' -or $a -eq 'no') { return $false }
    }
}

function Ask-Word([string]$Question, [string]$Word) {
    if ($Yes) { Say ($Question + ' ' + $Word + '  [-Yes]'); return $true }
    $a = (Read-Host ($Question + ' Type ' + $Word + ' to continue, anything else to stop')).Trim()
    return ($a -ceq $Word)
}

function Get-Letter($Partition) {
    return ("$($Partition.DriveLetter)").Trim([char]0).Trim()
}

function Get-Layout([int]$DiskNumber) {
    Update-HostStorageCache
    return @(Get-Partition -DiskNumber $DiskNumber | Sort-Object Offset)
}

function Show-Layout([int]$DiskNumber) {
    Get-Layout $DiskNumber |
        Select-Object PartitionNumber,
            @{ n = 'Letter';   e = { Get-Letter $_ } },
            Type,
            @{ n = 'SizeGB';   e = { ToGB $_.Size } },
            @{ n = 'OffsetGB'; e = { ToGB $_.Offset } } |
        Format-Table -AutoSize | Out-Host
}

function Get-FreeLetter {
    $used = @()
    $used += (Get-Volume | ForEach-Object { "$($_.DriveLetter)".Trim([char]0).Trim() } | Where-Object { $_ })
    $used += (Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
    foreach ($c in 'T', 'S', 'R', 'U', 'V', 'W', 'X', 'Y', 'Z', 'Q', 'P', 'O', 'N', 'M') {
        if ($used -notcontains $c) { return $c }
    }
    throw 'No free drive letter is available for the temporary drive.'
}

function Get-UsedBytes([string]$Letter) {
    $v = Get-Volume -DriveLetter $Letter
    return ([int64]$v.Size - [int64]$v.SizeRemaining)
}

function Get-ProcessesOn([string]$Letter) {
    return @(Get-Process | Where-Object {
        $path = $null
        try { $path = $_.Path } catch { }
        $path -and $path.ToUpper().StartsWith($Letter.ToUpper() + ':\')
    })
}

# Walks a folder tree without following junctions / directory symlinks.
# Uses \\?\ paths so names longer than 260 characters work.
function Get-Tree([string]$Root, [switch]$LinksOnly) {
    $base = '\\?\' + $Root.TrimEnd('\')
    $files = New-Object 'System.Collections.Generic.List[string]'
    $links = New-Object 'System.Collections.Generic.List[string]'
    $unreadable = 0
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push('')
    while ($stack.Count -gt 0) {
        $rel = $stack.Pop()
        $dir = $base + '\' + $rel
        try { $subs = [System.IO.Directory]::GetDirectories($dir) } catch { $unreadable++; continue }
        foreach ($s in $subs) {
            $name = [System.IO.Path]::GetFileName($s)
            if (-not $rel -and ($name -eq 'System Volume Information' -or $name -eq '$RECYCLE.BIN')) { continue }
            $childRel = $name
            if ($rel) { $childRel = $rel + '\' + $name }
            try { $attr = [System.IO.File]::GetAttributes($s) } catch { $unreadable++; continue }
            if ($attr -band [System.IO.FileAttributes]::ReparsePoint) { $links.Add($childRel) } else { $stack.Push($childRel) }
        }
        if (-not $LinksOnly) {
            try {
                foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
                    $name = [System.IO.Path]::GetFileName($f)
                    if ($rel) { $files.Add($rel + '\' + $name) } else { $files.Add($name) }
                }
            } catch { $unreadable++ }
        }
    }
    return New-Object psobject -Property @{ Base = $base; Files = $files; Links = $links; Unreadable = $unreadable }
}

function Get-Sha256([string]$Path) {
    $fs = $null
    $sha = $null
    try {
        $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $sha = [System.Security.Cryptography.SHA256]::Create()
        return [System.BitConverter]::ToString($sha.ComputeHash($fs))
    } catch {
        return $null
    } finally {
        if ($sha) { $sha.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

# Content check: every file under FromRoot must exist under ToRoot with the
# same SHA-256.
function Compare-TreeHash([string]$FromRoot, [string]$ToRoot) {
    $tree = Get-Tree $FromRoot
    $toBase = '\\?\' + $ToRoot.TrimEnd('\')
    $bad = New-Object 'System.Collections.Generic.List[string]'
    $unread = 0
    $i = 0
    $total = $tree.Files.Count
    foreach ($rel in $tree.Files) {
        $i++
        if ($i % 100 -eq 0) {
            Write-Progress -Activity 'Comparing file contents (SHA-256)' -Status ($i.ToString() + ' of ' + $total) -PercentComplete ([int](100 * $i / [math]::Max(1, $total)))
        }
        $h1 = Get-Sha256 ($tree.Base + '\' + $rel)
        if (-not $h1) { $unread++; continue }
        $h2 = Get-Sha256 ($toBase + '\' + $rel)
        if ($h1 -ne $h2) { $bad.Add($rel) }
    }
    Write-Progress -Activity 'Comparing file contents (SHA-256)' -Completed
    return New-Object psobject -Property @{
        Ok         = ($bad.Count -eq 0)
        Count      = $total
        Mismatch   = $bad
        Unreadable = ($unread + $tree.Unreadable)
    }
}

# robocopy needs drive roots as  D:\  and folders without a trailing backslash.
function Get-RoboPath([string]$Path) {
    if ($Path -match '^[A-Za-z]:\\?$') { return ($Path.Substring(0, 2) + '\') }
    return $Path.TrimEnd('\')
}

function Get-ExcludeDirs([string]$Root) {
    $r = $Root.TrimEnd('\')
    return @(($r + '\System Volume Information'), ($r + '\' + '$RECYCLE.BIN'))
}

# Copies a whole tree with robocopy and shows progress. Returns the robocopy
# exit code (8 or higher means something failed).
function Copy-Tree([string]$FromRoot, [string]$ToRoot, [string]$LogFile, [int64]$ExpectedBytes, [string]$ProgressLetter) {
    $ex = Get-ExcludeDirs $FromRoot
    $src = Get-RoboPath $FromRoot
    $dst = Get-RoboPath $ToRoot
    if ($src -notmatch '\\$') { $src = '"' + $src + '"' }
    if ($dst -notmatch '\\$') { $dst = '"' + $dst + '"' }
    $argLine = ('{0} {1} /E {2} /DCOPY:DAT /XJ /R:1 /W:1 /NP /NFL /NDL "/LOG:{3}" /XD "{4}" "{5}"' -f $src, $dst, ($script:RoboCopyFlags -join ' '), $LogFile, $ex[0], $ex[1])
    $baseline = 0
    if ($ProgressLetter) { $baseline = Get-UsedBytes $ProgressLetter }
    $proc = Start-Process -FilePath 'robocopy.exe' -ArgumentList $argLine -PassThru -WindowStyle Hidden
    $null = $proc.Handle
    $activity = 'Copying ' + $FromRoot + ' to ' + $ToRoot
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 1500
        if ($ProgressLetter) {
            try {
                $done = (Get-UsedBytes $ProgressLetter) - $baseline
                $pct = 0
                if ($ExpectedBytes -gt 0) { $pct = [int][math]::Min(99, [math]::Max(0, 100 * $done / $ExpectedBytes)) }
                Write-Progress -Activity $activity -Status ((ToGB $done) + ' GB of about ' + (ToGB $ExpectedBytes) + ' GB') -PercentComplete $pct
            } catch { }
        }
    }
    Write-Progress -Activity $activity -Completed
    return $proc.ExitCode
}

# Second robocopy pass in list-only mode: lists anything that is missing or
# different (size / timestamp) on the destination. Ok only when nothing is.
function Test-TreeCopy([string]$FromRoot, [string]$ToRoot) {
    $ex = Get-ExcludeDirs $FromRoot
    $a = @((Get-RoboPath $FromRoot), (Get-RoboPath $ToRoot), '/L', '/E', '/XJ', '/XX', '/R:0', '/W:0', '/NJH', '/NJS', '/NDL', '/NP', '/FP')
    $a += $script:RoboVerifyFlags
    $a += @('/XD', $ex[0], $ex[1])
    $out = & robocopy.exe @a
    $code = $LASTEXITCODE
    $lines = @($out | Where-Object { $_ -and $_.Trim() })
    return New-Object psobject -Property @{
        Ok    = (($code -band 29) -eq 0)
        Code  = $code
        Lines = $lines
    }
}

function Get-WinReInfo {
    $text = (& reagentc.exe /info | Out-String)
    $info = New-Object psobject -Property @{ Enabled = $false; Disk = -1; Partition = -1 }
    if ($text -match 'harddisk(\d+)\\partition(\d+)') {
        $info.Enabled = $true
        $info.Disk = [int]$Matches[1]
        $info.Partition = [int]$Matches[2]
    }
    return $info
}

function Remove-PartitionAtOffset([int]$DiskNumber, [int64]$Offset) {
    $p = Get-Layout $DiskNumber | Where-Object { [int64]$_.Offset -eq $Offset }
    if (-not $p) { return }
    try {
        Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
    } catch {
        Say ('  Remove-Partition refused, retrying with diskpart: ' + $_.Exception.Message) 'Yellow'
        $dp = Join-Path $env:TEMP 'ezmv-diskpart.txt'
        Set-Content -Path $dp -Encoding ASCII -Value @(
            ('select disk ' + $DiskNumber),
            ('select partition ' + $p.PartitionNumber),
            'delete partition override'
        )
        & diskpart.exe /s $dp | Out-Host
        Remove-Item $dp -Force -ErrorAction SilentlyContinue
    }
    $still = Get-Layout $DiskNumber | Where-Object { [int64]$_.Offset -eq $Offset }
    if ($still) { throw ('Could not delete the partition at offset ' + (ToGB $Offset) + ' GB.') }
}

# Creates and formats a drive in the largest free region, and checks that it
# landed where expected. Reuses an existing drive with that letter if a
# previous, interrupted run already created it in the right place.
function New-DataDrive([int]$DiskNumber, [string]$Letter, [string]$Label, [int64]$AllocUnit, [int64]$MinOffset, [int64]$MaxOffset) {
    Update-HostStorageCache
    $p = Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue
    if ($p) {
        if ([int]$p.DiskNumber -ne $DiskNumber -or [int64]$p.Offset -lt $MinOffset -or [int64]$p.Offset -gt $MaxOffset) {
            throw ('Drive letter ' + $Letter + ': is already used by another partition.')
        }
    } else {
        $p = New-Partition -DiskNumber $DiskNumber -UseMaximumSize -DriveLetter $Letter
        if ([int64]$p.Offset -lt $MinOffset -or [int64]$p.Offset -gt $MaxOffset) {
            Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
            throw ('The new partition landed in an unexpected place (offset ' + (ToGB $p.Offset) + ' GB). It was removed again.')
        }
        Start-Sleep -Seconds 2
    }
    $fs = "$((Get-Volume -Partition $p).FileSystem)"
    if ($fs -ne 'NTFS') {
        try {
            if ($AllocUnit -gt 0) {
                Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel $Label -AllocationUnitSize $AllocUnit -Confirm:$false | Out-Null
            } else {
                Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel $Label -Confirm:$false | Out-Null
            }
        } catch {
            try { Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false } catch { }
            throw ('Formatting ' + $Letter + ': failed: ' + $_.Exception.Message)
        }
        Start-Sleep -Seconds 2
    }
    return (Get-Partition -DriveLetter $Letter)
}

# Owner of a file or folder as a SID string.
function Get-OwnerSid([string]$Path) {
    return (Get-Acl -LiteralPath $Path).GetOwner([System.Security.Principal.SecurityIdentifier]).Value
}

function Test-TrustedOwner([string]$Path) {
    $sid = Get-OwnerSid $Path
    return ($sid -eq $SidAdmins -or $sid -eq $SidSystem)
}

# Gives a file or folder an ACL that only Administrators and SYSTEM can use,
# owned by Administrators. A normal user can then neither read nor change it.
function Protect-AdminOnly([string]$Path) {
    $admins = New-Object System.Security.Principal.SecurityIdentifier($SidAdmins)
    $system = New-Object System.Security.Principal.SecurityIdentifier($SidSystem)
    $isDir = (Get-Item -LiteralPath $Path -Force).PSIsContainer
    if ($isDir) {
        $acl = New-Object System.Security.AccessControl.DirectorySecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    } else {
        $acl = New-Object System.Security.AccessControl.FileSecurity
        $inherit = [System.Security.AccessControl.InheritanceFlags]::None
    }
    $prop = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $full = [System.Security.AccessControl.FileSystemRights]::FullControl
    $acl.SetOwner($admins)
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, $full, $inherit, $prop, $allow)))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, $full, $inherit, $prop, $allow)))
    # SetAccessControl writes only the owner and the DACL (Set-Acl can also try
    # to write the audit list, which needs an extra privilege).
    (Get-Item -LiteralPath $Path -Force).SetAccessControl($acl)
}

function Save-State($State, [string]$Path) {
    $dir = Split-Path $Path -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = $Path + '.tmp'
    if (Test-Path $tmp) { Remove-Item -Path $tmp -Force }
    $State | ConvertTo-Json -Depth 5 | Set-Content -Path $tmp -Encoding UTF8
    if ($script:ProtectState) { Protect-AdminOnly $tmp }
    Move-Item -Path $tmp -Destination $Path -Force
}

function Read-State([string]$Path) {
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Path $Path -Raw | ConvertFrom-Json) } catch { return $null }
}

function Get-StateText($State) {
    if (-not $State) { return 'Nothing on the disk was changed.' }
    $d = $State.DonorLetter + ':'
    $t = $State.TempLetter + ':'
    $c = $State.TargetLetter + ':'
    $again = ' Start ezmv again to continue or to roll back.'
    switch ([int]$State.Phase) {
        0 { return 'Nothing on the disk was changed.' }
        1 { return ($d + ' was shrunk, nothing else changed. All files are still on ' + $d + '.' + $again) }
        2 { return ('All files are still on ' + $d + '. ' + $t + ' is an empty temporary drive.' + $again) }
        3 { return ('All files are still on ' + $d + '. ' + $t + ' holds a verified copy.' + $again) }
        4 { return ('The old ' + $d + ' is deleted. YOUR FILES ARE ONLY ON ' + $t + ' - do not delete ' + $t + '.' + ' Start ezmv again to continue.') }
        5 { return ('YOUR FILES ARE ONLY ON ' + $t + ' - do not delete ' + $t + '. Start ezmv again to continue.') }
        6 { return ($c + ' has been extended. YOUR FILES ARE ONLY ON ' + $t + ' - do not delete ' + $t + '. Start ezmv again to continue.') }
        7 { return ('A new empty ' + $d + ' exists. YOUR FILES ARE ON ' + $t + ' - do not delete ' + $t + '. Start ezmv again to continue.') }
        8 { return ('Your files are on both ' + $d + ' and ' + $t + '. Start ezmv again to finish.') }
        9 { return ('Almost done: only growing ' + $d + ' is left. Start ezmv again to finish.') }
        default { return 'The disk work is complete.' }
    }
}

# Rolls back steps 1-3 (before anything was deleted): removes the temporary
# drive and grows the data drive back.
function Undo-Early($State) {
    $diskNo = [int]$State.DiskNumber
    if ([int64]$State.TempOffset -gt 0) {
        $tp = Get-Layout $diskNo | Where-Object { [int64]$_.Offset -eq [int64]$State.TempOffset }
        if ($tp -and (Get-Letter $tp) -eq $State.TempLetter) {
            Remove-PartitionAtOffset $diskNo ([int64]$State.TempOffset)
        }
    }
    Update-HostStorageCache
    $max = [int64](Get-PartitionSupportedSize -DriveLetter $State.DonorLetter).SizeMax
    if ($max -gt [int64](Get-Partition -DriveLetter $State.DonorLetter).Size) {
        Resize-Partition -DriveLetter $State.DonorLetter -Size $max
    }
}

if ($IsDotSourced) { return }

# --------------------------------------------------------------------- main --
$S = $null
$exitCode = 0
$bitLockerSuspended = $false
$shellSvcStopped = $false
$winReDisabled = $false
$transcriptOn = $false

$defaultStateDir = Join-Path $env:ProgramData 'ezmv'
$usingDefaultState = (-not $StatePath)
if ($usingDefaultState) { $StatePath = Join-Path $defaultStateDir 'state.json' }
$script:ProtectState = $true
$logDir = Join-Path (Split-Path $StatePath -Parent) 'logs'

function Complete-Phase([int]$Number) {
    $S.Phase = $Number
    Save-State $S $StatePath
    if ($StopAfterPhase -eq $Number) { throw ('Stopped after step ' + $Number + ' because of -StopAfterPhase (testing).') }
}

try {
    Set-Location ($env:SystemDrive + '\')
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'

    # The resume file tells an elevated ezmv which partitions to delete, so it
    # must not be writable by normal users. %ProgramData% lets any user create
    # folders, so the default folder is checked and locked down first.
    if ($usingDefaultState) {
        if (Test-Path $defaultStateDir) {
            if (-not (Test-TrustedOwner $defaultStateDir)) {
                throw ($defaultStateDir + ' is owned by ' + (Get-OwnerSid $defaultStateDir) + ', not by Administrators. Someone else may have created it to tamper with ezmv. Check what is in it, delete it, then run ezmv again.')
            }
        } else {
            New-Item -ItemType Directory -Path $defaultStateDir -Force | Out-Null
        }
        Protect-AdminOnly $defaultStateDir
    }
    if ((Test-Path $StatePath) -and -not (Test-TrustedOwner $StatePath)) {
        throw ('The resume file ' + $StatePath + ' is owned by ' + (Get-OwnerSid $StatePath) + ', not by Administrators, so it may have been tampered with. ezmv will not act on it. Check it, delete it if you did not create it, then run ezmv again.')
    }
    if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
    try { Start-Transcript -Path (Join-Path $logDir ('session_' + $stamp + '.log')) | Out-Null; $transcriptOn = $true } catch { }

    Say ''
    Say ('  ezmv ' + $EzmvVersion + ' - move free space to the drive on the left') 'White'
    Say '  ------------------------------------------------------------' 'White'
    if ($PlanOnly) { Say '  PLAN ONLY mode: nothing will be changed.' 'Yellow' }

    # ---- unfinished run? ---------------------------------------------------
    $saved = Read-State $StatePath
    if ($saved -and [int]$saved.Phase -ge 10) {
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        $saved = $null
    }
    if ($saved) {
        Step 'An unfinished run was found'
        Say ('  Started:  ' + $saved.Started)
        Say ('  Job:      give ' + (ToGB $saved.GiveBytes) + ' GB from ' + $saved.DonorLetter + ': to ' + $saved.TargetLetter + ':')
        Say ('  Progress: step ' + $saved.Phase + ' of 10 finished')
        Say ('  State:    ' + (Get-StateText $saved)) 'Yellow'
        if ($PlanOnly) { Say ''; Say 'PLAN ONLY mode: stopping here.' 'Yellow'; return }

        $sameDisk = $false
        try { $sameDisk = ("$((Get-Disk -Number ([int]$saved.DiskNumber)).Guid)" -eq "$($saved.DiskGuid)") } catch { }
        if (-not $sameDisk) { throw ('The saved run belongs to a disk that is not attached (or its number changed). Resume file: ' + $StatePath) }

        if (Ask-YesNo 'Continue this run?') {
            $S = $saved
        } elseif ([int]$saved.Phase -le 3) {
            if (Ask-YesNo ('Roll back instead (remove the temporary drive and grow ' + $saved.DonorLetter + ': back)?')) {
                Step 'Rolling back'
                Undo-Early $saved
                Remove-Item $StatePath -Force
                # undo what an earlier, interrupted run left suspended (done in finally)
                $cL = "$($saved.TargetLetter)"
                if ([bool]$saved.BitLockerSuspended) { $bitLockerSuspended = $true }
                if ([bool]$saved.WinReDisabled) { $winReDisabled = $true }
                Say '  Rolled back. The disk is as it was before.' 'Green'
                Show-Layout ([int]$saved.DiskNumber)
            }
            return
        } else {
            Say '  This run is past the point where it can be rolled back. Start ezmv again when you want to continue.' 'Yellow'
            return
        }
    }

    # ---- fresh run: detect, check, ask ------------------------------------
    if (-not $S) {
        Step 'Detecting the disk layout'
        $tLetterIn = $env:SystemDrive.TrimEnd(':')
        if ($Target) { $tLetterIn = $Target.Trim().TrimEnd(':').ToUpper() }
        if ($tLetterIn -notmatch '^[A-Za-z]$') { throw ('"' + $Target + '" is not a drive letter.') }
        $cPart = Get-Partition -DriveLetter $tLetterIn
        $diskNo = [int]$cPart.DiskNumber
        $disk = Get-Disk -Number $diskNo
        if ($disk.PartitionStyle -ne 'GPT') { throw 'Only GPT disks are supported.' }

        Say ('Target drive:  ' + $tLetterIn + ':  on disk ' + $diskNo + ' (' + $disk.FriendlyName + ', ' + (ToGB $disk.Size) + ' GB)')
        Show-Layout $diskNo

        $cEnd = [int64]$cPart.Offset + [int64]$cPart.Size
        $between = @()
        $donor = $null
        foreach ($p in (Get-Layout $diskNo | Where-Object { [int64]$_.Offset -gt [int64]$cPart.Offset })) {
            if ((Get-Letter $p) -and $p.Type -eq 'Basic') { $donor = $p; break }
            $between += $p
        }
        if (-not $donor) { throw ('No data drive with a letter was found after ' + $tLetterIn + ': on the same disk.') }
        $dLetter = Get-Letter $donor

        foreach ($p in $between) {
            if ("$($p.GptType)".ToLower() -ne $RecoveryGptType) {
                throw ('Partition ' + $p.PartitionNumber + ' (' + $p.Type + ') sits between ' + $tLetterIn + ': and ' + $dLetter + ': and is not a recovery partition. Stopping to be safe.')
            }
        }

        $dVol = Get-Volume -DriveLetter $dLetter
        if ($dVol.FileSystem -ne 'NTFS') { throw ($dLetter + ': is ' + $dVol.FileSystem + ', only NTFS is supported.') }
        $dLabel = "$($dVol.FileSystemLabel)"
        $dSize = [int64]$donor.Size
        $dOffset = [int64]$donor.Offset
        $used = Get-UsedBytes $dLetter
        $gap = $dOffset - $cEnd
        $wmiVol = Get-CimInstance Win32_Volume -Filter ("DriveLetter='" + $dLetter + ":'") -ErrorAction SilentlyContinue
        $allocUnit = 0
        if ($wmiVol -and $wmiVol.BlockSize) { $allocUnit = [int64]$wmiVol.BlockSize }

        Say ('Data drive:    ' + $dLetter + ':  "' + $dLabel + '"  ' + (ToGB $dSize) + ' GB, ' + (ToGB $used) + ' GB used')
        if ($between.Count -gt 0) {
            Say ('In between:    ' + $between.Count + ' recovery partition(s), ' + (ToGB $gap) + ' GB')
        } else {
            Say 'In between:    nothing'
        }

        Step 'Running safety checks'

        if ($PSCommandPath -and $PSCommandPath.ToUpper().StartsWith($dLetter.ToUpper() + ':')) {
            throw ('ezmv is stored on ' + $dLetter + ':, which will be deleted and recreated. Copy it to another drive and run it from there.')
        }
        if ($StatePath.ToUpper().StartsWith($dLetter.ToUpper() + ':')) {
            throw ('The resume file would be stored on ' + $dLetter + ':. Choose another -StatePath.')
        }

        if ([int64]$disk.LargestFreeExtent -gt 64MB) {
            throw ('The disk already has ' + (ToGB $disk.LargestFreeExtent) + ' GB of unallocated space. Extend a drive into it (or remove it) first, then run ezmv again.')
        }

        if ($wmiVol -and $wmiVol.DirtyBitSet -eq $true) {
            throw ($dLetter + ': is marked as needing a disk check. Run  chkdsk ' + $dLetter + ': /f  first.')
        }
        Say '  file system state: ok'

        $pageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ($dLetter + ':*') })
        if ($pageFiles.Count -gt 0) {
            throw ('A page file is on ' + $dLetter + ':. Move it to another drive (System > Advanced > Performance > Virtual memory), reboot, then run ezmv again.')
        }
        Say '  page file is not on the data drive: ok'

        while ($true) {
            $procs = Get-ProcessesOn $dLetter
            if ($procs.Count -eq 0) { Say ('  programs running from ' + $dLetter + ': none'); break }
            Say ('  ' + $procs.Count + ' program(s) are running from ' + $dLetter + ':') 'Yellow'
            $procs | Select-Object -First 10 | ForEach-Object { Say ('    ' + $_.ProcessName + '  (' + $_.Path + ')') 'Yellow' }
            if ($PlanOnly) { break }
            if ($Yes) { throw ('Programs are running from ' + $dLetter + ':. Close them first.') }
            $null = Read-Host '  Close them, then press Enter to check again'
        }

        $battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
        if ($battery.Count -gt 0 -and @(1, 4, 5) -contains [int]$battery[0].BatteryStatus) {
            Say '  The computer is running on battery. If it runs out mid-copy the run stops and has to be resumed.' 'Yellow'
            if (-not $PlanOnly -and -not (Ask-YesNo '  Continue on battery anyway?')) { throw 'Stopped: plug in the charger and run again.' }
        } else {
            Say '  power: ok'
        }

        $cBl = $null; $dBl = $null
        try { $cBl = Get-BitLockerVolume -MountPoint ($tLetterIn + ':') } catch { }
        try { $dBl = Get-BitLockerVolume -MountPoint ($dLetter + ':') } catch { }
        $cProtected = ($cBl -and "$($cBl.ProtectionStatus)" -eq 'On')
        $dEncrypted = ($dBl -and "$($dBl.VolumeStatus)" -ne 'FullyDecrypted')
        if ($dBl -and "$($dBl.LockStatus)" -eq 'Locked') { throw ($dLetter + ': is locked by BitLocker. Unlock it first.') }
        foreach ($bl in @($cBl, $dBl)) {
            if ($bl -and "$($bl.VolumeStatus)" -like '*InProgress*') {
                throw ('BitLocker is still encrypting or decrypting ' + $bl.MountPoint + ' (' + $bl.VolumeStatus + '). Wait until it has finished, then run ezmv again.')
            }
        }
        if ($cBl -and -not $cProtected) { Say ('  BitLocker on ' + $tLetterIn + ': is off or already suspended -> nothing to suspend') }
        if ($dBl -and -not $dEncrypted) { Say ('  BitLocker on ' + $dLetter + ': is off -> nothing to do') }
        if ($cProtected) { Say ('  BitLocker on ' + $tLetterIn + ': is ON -> suspended during the work, resumed at the end') }
        if ($dEncrypted) { Say ('  BitLocker on ' + $dLetter + ': is ON -> the recreated ' + $dLetter + ': will NOT be encrypted until you turn it on again') 'Yellow' }
        if (-not $cBl -and -not $dBl) { Say '  BitLocker status could not be read (continuing).' 'Yellow' }

        $winRe = Get-WinReInfo
        $winReBetween = ($winRe.Enabled -and $winRe.Disk -eq $diskNo -and @($between | Where-Object { [int]$_.PartitionNumber -eq $winRe.Partition }).Count -gt 0)
        if ($winReBetween) {
            Say ('  Windows Recovery lives on the partition being removed (partition ' + $winRe.Partition + ') -> disabled during the work, re-enabled at the end')
        } elseif ($between.Count -gt 0) {
            Say '  The recovery partition in between is not in active use by Windows Recovery.'
        }

        Say '  looking for folder links (junctions) on the data drive...'
        $tree = Get-Tree ($dLetter + ':\') -LinksOnly
        if ($tree.Links.Count -gt 0) {
            Say ('  ' + $tree.Links.Count + ' folder link(s) found. They will NOT be recreated on the new drive:') 'Yellow'
            $tree.Links | Select-Object -First 10 | ForEach-Object { Say ('    ' + $dLetter + ':\' + $_) 'Yellow' }
            if ($tree.Links.Count -gt 10) { Say ('    ... and ' + ($tree.Links.Count - 10) + ' more') 'Yellow' }
        } else {
            Say '  folder links: none'
        }

        # size maths
        $support = Get-PartitionSupportedSize -DriveLetter $dLetter
        $dMin = [int64]$support.SizeMin
        $need = CeilMB (([double]$used * 1.03) + 512MB)      # room the files need, with margin
        $dShrunk = FloorMB ($dSize - $need)                  # data drive size after shrinking
        if ($dShrunk -lt $dMin) {
            throw ($dLetter + ': can only shrink to ' + (ToGB $dMin) + ' GB, but it must shrink to ' + (ToGB $dShrunk) + ' GB to make room for a temporary copy. Free up or defragment ' + $dLetter + ':, or use a partition tool that can move partitions.')
        }
        $maxGive = [int][math]::Floor(($gap + $dShrunk - $need) / 1GB) - 1
        if ($maxGive -lt 1) {
            throw ($dLetter + ': is too full for this method (the files must fit twice). Free up space on ' + $dLetter + ': first.')
        }

        Step 'Your choices'
        if (-not (Ask-YesNo ('Take space from ' + $dLetter + ': and give it to ' + $tLetterIn + ':?'))) { throw 'Stopped by you.' }

        $give = $GiveGB
        if ($give -ne 0 -and ($give -lt 1 -or $give -gt $maxGive)) { throw ('-GiveGB must be between 1 and ' + $maxGive + '.') }
        $default = [math]::Min(10, $maxGive)
        if ($give -eq 0 -and $Yes) { $give = $default }
        while ($give -lt 1 -or $give -gt $maxGive) {
            $raw = (Read-Host ('How many GB to give to ' + $tLetterIn + ':? (1-' + $maxGive + ') [' + $default + ']')).Trim()
            if (-not $raw) { $give = $default; break }
            $n = 0
            if ([int]::TryParse($raw, [ref]$n)) { $give = $n }
        }
        $giveBytes = [int64]$give * 1GB
        $tempLetter = Get-FreeLetter
        $cNew = [int64]$cPart.Size + $giveBytes
        $dFinal = $dSize + $gap - $giveBytes

        Step 'Plan'
        Say ('   1. Shrink ' + $dLetter + ': from ' + (ToGB $dSize) + ' GB to ' + (ToGB $dShrunk) + ' GB')
        Say ('   2. Create temporary drive ' + $tempLetter + ': (' + (ToGB ($dSize - $dShrunk)) + ' GB)')
        Say ('   3. Copy ' + (ToGB $used) + ' GB of files to ' + $tempLetter + ': and verify')
        Say ('   4. DELETE the old ' + $dLetter + ':') 'Yellow'
        if ($between.Count -gt 0) {
            Say ('   5. DELETE ' + $between.Count + ' recovery partition(s) between ' + $tLetterIn + ': and ' + $dLetter + ':') 'Yellow'
        } else {
            Say '   5. (no recovery partition to remove)'
        }
        Say ('   6. Extend ' + $tLetterIn + ': from ' + (ToGB $cPart.Size) + ' GB to ' + (ToGB $cNew) + ' GB')
        Say ('   7. Create a new ' + $dLetter + ':')
        Say ('   8. Copy the files back and verify')
        Say ('   9. Delete ' + $tempLetter + ':')
        Say ('  10. Grow ' + $dLetter + ': to about ' + (ToGB $dFinal) + ' GB')
        Say ''
        Say ('  Result:  ' + $tLetterIn + ': ' + (ToGB $cNew) + ' GB    ' + $dLetter + ': about ' + (ToGB $dFinal) + ' GB') 'Green'
        Say ''
        Say '  Lost in the process: restore points / shadow copies on the data drive, its recycle bin,' 'DarkGray'
        Say '  folder links on it, and its BitLocker encryption (turn it on again afterwards).' 'DarkGray'

        if ($PlanOnly) {
            Say ''
            Say 'PLAN ONLY mode: stopping here. Nothing was changed.' 'Yellow'
            return
        }

        Step 'Before you confirm'
        Say '  - Close every program that uses the data drive (downloads, games, editors, Explorer windows).'
        Say '  - Back up anything on the data drive that you cannot afford to lose.'
        if ($cProtected -or $dEncrypted) {
            Say '  - Save your BitLocker recovery keys: https://account.microsoft.com/devices/recoverykey'
            Say ('    or run:  manage-bde -protectors -get ' + $tLetterIn + ':')
            if (-not (Ask-YesNo 'Do you have your BitLocker recovery key saved somewhere safe?')) { throw 'Stopped: save the recovery key first.' }
        }
        if (-not (Ask-Word 'Ready to change the disk.' 'YES')) { throw 'Stopped by you.' }

        $S = [pscustomobject]@{
            Version        = $EzmvVersion
            Started        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Phase          = 0
            DiskNumber     = $diskNo
            DiskGuid       = "$($disk.Guid)"
            TargetLetter   = $tLetterIn
            TargetOrigSize = [int64]$cPart.Size
            DonorLetter    = $dLetter
            DonorLabel     = $dLabel
            DonorOffset    = $dOffset
            DonorSize      = $dSize
            DonorShrunk    = $dShrunk
            DonorEncrypted = [bool]$dEncrypted
            AllocUnit      = $allocUnit
            Used           = $used
            GiveBytes      = $giveBytes
            TempLetter     = $tempLetter
            TempOffset     = [int64]0
            BetweenOffsets = @($between | ForEach-Object { [int64]$_.Offset })
            VerifyHash     = [bool]$VerifyHash
            BitLockerSuspended = $false
            WinReDisabled  = $false
        }
        Save-State $S $StatePath
    }

    # ---- run (fresh or resumed) -------------------------------------------
    $diskNo = [int]$S.DiskNumber
    $cL = "$($S.TargetLetter)"
    $dL = "$($S.DonorLetter)"
    $tL = "$($S.TempLetter)"
    $used = [int64]$S.Used
    $doHash = ([bool]$S.VerifyHash -or [bool]$VerifyHash)

    # Resume files from 0.9.0 do not have these fields yet.
    foreach ($f in 'BitLockerSuspended', 'WinReDisabled') {
        if (-not ($S.PSObject.Properties.Name -contains $f)) { $S | Add-Member -NotePropertyName $f -NotePropertyValue $false }
    }
    # If an earlier run suspended BitLocker or disabled Windows Recovery and then
    # died (power cut, closed window), this run has to undo that at the end.
    if ([bool]$S.BitLockerSuspended) { $bitLockerSuspended = $true }
    if ([bool]$S.WinReDisabled) { $winReDisabled = $true }

    $svc = Get-Service -Name ShellHWDetection -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq 'Running') {
        try { Stop-Service -Name ShellHWDetection -Force; $shellSvcStopped = $true } catch { }
    }

    $cBlNow = $null
    try { $cBlNow = Get-BitLockerVolume -MountPoint ($cL + ':') } catch { }
    if ($cBlNow -and "$($cBlNow.ProtectionStatus)" -eq 'On') {
        Step ('Suspending BitLocker on ' + $cL + ':')
        $S.BitLockerSuspended = $true
        Save-State $S $StatePath
        $bitLockerSuspended = $true
        Suspend-BitLocker -MountPoint ($cL + ':') -RebootCount 0 | Out-Null
    }

    if ([int]$S.Phase -lt 1) {
        Step ('Step 1/10: shrinking ' + $dL + ':')
        if ([int64](Get-Partition -DriveLetter $dL).Size -gt [int64]$S.DonorShrunk) {
            Resize-Partition -DriveLetter $dL -Size ([int64]$S.DonorShrunk)
        }
        Complete-Phase 1
    }

    if ([int]$S.Phase -lt 2) {
        Step ('Step 2/10: creating temporary drive ' + $tL + ':')
        $tPart = New-DataDrive $diskNo $tL $TempLabel ([int64]$S.AllocUnit) ([int64]$S.DonorOffset + [int64]$S.DonorShrunk) ([int64]$S.DonorOffset + [int64]$S.DonorSize)
        $S.TempOffset = [int64]$tPart.Offset
        if ([int64](Get-Volume -DriveLetter $tL).SizeRemaining -le $used) { throw ('The temporary drive is too small for the files on ' + $dL + ':.') }
        Complete-Phase 2
    }

    if ([int]$S.Phase -lt 3) {
        Step ('Step 3/10: copying ' + $dL + ': to ' + $tL + ': (' + (ToGB $used) + ' GB, this can take a while)')
        $log = Join-Path $logDir ('copy_to_temp_' + $stamp + '.log')
        $code = Copy-Tree ($dL + ':\') ($tL + ':\') $log $used $tL
        if ($code -ge 8) { throw ('The copy reported failures (robocopy code ' + $code + '). See ' + $log) }
        Say '  verifying...'
        $check = Test-TreeCopy ($dL + ':\') ($tL + ':\')
        if (-not $check.Ok) {
            Say ('  ' + $check.Lines.Count + ' item(s) differ or are missing on ' + $tL + ':') 'Red'
            $check.Lines | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_.Trim()) 'Red' }
            throw 'Verification failed. Close programs that use the data drive, then start ezmv again.'
        }
        if ($doHash) {
            $h = Compare-TreeHash ($dL + ':\') ($tL + ':\')
            if (-not $h.Ok) {
                $h.Mismatch | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_) 'Red' }
                throw ('Content check failed for ' + $h.Mismatch.Count + ' file(s).')
            }
            Say ('  content check: ' + $h.Count + ' files identical, ' + $h.Unreadable + ' could not be read') 'Green'
        }
        Say ('  Every file on ' + $dL + ': is present on ' + $tL + ': with the same size and date.') 'Green'
        Complete-Phase 3
    }

    if ([int]$S.Phase -lt 4) {
        Say ''
        Say ('POINT OF NO RETURN: the old ' + $dL + ': will now be deleted. Your files will live only on ' + $tL + ': until they are copied back.') 'Yellow'
        if (-not (Ask-Word ('Delete the old ' + $dL + ':?') 'DELETE')) {
            if (Ask-YesNo ('Roll back now (remove ' + $tL + ': and grow ' + $dL + ': back)?')) {
                Step 'Rolling back'
                Undo-Early $S
                Remove-Item $StatePath -Force
                $S = $null
                Say '  Rolled back. The disk is as it was before.' 'Green'
                Show-Layout $diskNo
                return
            }
            throw 'Stopped by you before deleting anything.'
        }
        Step ('Step 4/10: deleting the old ' + $dL + ':')
        $old = Get-Layout $diskNo | Where-Object { [int64]$_.Offset -eq [int64]$S.DonorOffset }
        if ($old -and (Get-Letter $old) -ne $dL) { throw ('The partition at the old position of ' + $dL + ': is not ' + $dL + ': any more. Stopping to be safe.') }
        Remove-PartitionAtOffset $diskNo ([int64]$S.DonorOffset)
        Complete-Phase 4
    }

    if ([int]$S.Phase -lt 5) {
        $offsets = @($S.BetweenOffsets | ForEach-Object { [int64]$_ })
        if ($offsets.Count -gt 0) {
            $winRe = Get-WinReInfo
            $rePart = $null
            if ($winRe.Enabled -and $winRe.Disk -eq $diskNo) {
                $rePart = Get-Layout $diskNo | Where-Object { [int]$_.PartitionNumber -eq $winRe.Partition }
            }
            if ($rePart -and ($offsets -contains [int64]$rePart.Offset)) {
                Step 'Disabling Windows Recovery (re-enabled at the end)'
                $S.WinReDisabled = $true
                Save-State $S $StatePath
                $winReDisabled = $true
                & reagentc.exe /disable | Out-Host
                $wim = Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim'
                if (-not (Test-Path $wim)) {
                    Say '  The recovery image was not moved to the Windows drive.' 'Yellow'
                    if (-not (Ask-YesNo '  Deleting the recovery partition may leave Windows without a recovery environment. Continue?')) {
                        throw 'Stopped by you before deleting the recovery partition.'
                    }
                }
            }
            foreach ($o in $offsets) {
                Step ('Step 5/10: deleting recovery partition at ' + (ToGB $o) + ' GB')
                Remove-PartitionAtOffset $diskNo $o
            }
        }
        Complete-Phase 5
    }

    if ([int]$S.Phase -lt 6) {
        Step ('Step 6/10: extending ' + $cL + ':')
        Update-HostStorageCache
        $wanted = [int64]$S.TargetOrigSize + [int64]$S.GiveBytes
        $now = [int64](Get-Partition -DriveLetter $cL).Size
        if ($now -lt ($wanted - 1MB)) {
            $cMax = [int64](Get-PartitionSupportedSize -DriveLetter $cL).SizeMax
            $cTarget = [math]::Min($wanted, $cMax)
            if ($cTarget -le $now) { throw ($cL + ': cannot be extended: Windows reports no free space next to it.') }
            Resize-Partition -DriveLetter $cL -Size $cTarget
        }
        Say ('  ' + $cL + ': is now ' + (ToGB (Get-Partition -DriveLetter $cL).Size) + ' GB') 'Green'
        Complete-Phase 6
    }

    if ([int]$S.Phase -lt 7) {
        Step ('Step 7/10: creating the new ' + $dL + ':')
        $cNow = Get-Partition -DriveLetter $cL
        $null = New-DataDrive $diskNo $dL $S.DonorLabel ([int64]$S.AllocUnit) ([int64]$cNow.Offset + [int64]$cNow.Size) ([int64]$S.TempOffset - 1)
        if ([int64](Get-Volume -DriveLetter $dL).SizeRemaining -le $used) { throw ('The new ' + $dL + ': is too small for the files. They are safe on ' + $tL + ':.') }
        Complete-Phase 7
    }

    if ([int]$S.Phase -lt 8) {
        Step ('Step 8/10: copying ' + $tL + ': back to ' + $dL + ':')
        $log = Join-Path $logDir ('copy_back_' + $stamp + '.log')
        $code = Copy-Tree ($tL + ':\') ($dL + ':\') $log $used $dL
        if ($code -ge 8) { throw ('The copy back reported failures (robocopy code ' + $code + '). See ' + $log + '. Your files are safe on ' + $tL + ':.') }
        Say '  verifying...'
        $check = Test-TreeCopy ($tL + ':\') ($dL + ':\')
        if (-not $check.Ok) {
            Say ('  ' + $check.Lines.Count + ' item(s) differ or are missing on ' + $dL + ':') 'Red'
            $check.Lines | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_.Trim()) 'Red' }
            throw ('Verification failed. Your files are safe on ' + $tL + ':. Start ezmv again to retry.')
        }
        if ($doHash) {
            $h = Compare-TreeHash ($tL + ':\') ($dL + ':\')
            if (-not $h.Ok) {
                $h.Mismatch | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_) 'Red' }
                throw ('Content check failed for ' + $h.Mismatch.Count + ' file(s). Your files are safe on ' + $tL + ':.')
            }
            Say ('  content check: ' + $h.Count + ' files identical, ' + $h.Unreadable + ' could not be read') 'Green'
        }
        Say ('  Every file is back on ' + $dL + ':.') 'Green'
        Complete-Phase 8
    }

    if ([int]$S.Phase -lt 9) {
        if (-not (Ask-YesNo ('Delete the temporary drive ' + $tL + ': and give its space back to ' + $dL + ':?'))) { throw 'Stopped by you.' }
        Step ('Step 9/10: deleting ' + $tL + ':')
        $tp = Get-Layout $diskNo | Where-Object { [int64]$_.Offset -eq [int64]$S.TempOffset }
        if ($tp -and (Get-Letter $tp) -ne $tL) { throw ('The partition at the position of ' + $tL + ': is not ' + $tL + ': any more. Stopping to be safe.') }
        Remove-PartitionAtOffset $diskNo ([int64]$S.TempOffset)
        Complete-Phase 9
    }

    if ([int]$S.Phase -lt 10) {
        Step ('Step 10/10: growing ' + $dL + ':')
        Update-HostStorageCache
        $dMax = [int64](Get-PartitionSupportedSize -DriveLetter $dL).SizeMax
        if ($dMax -gt [int64](Get-Partition -DriveLetter $dL).Size) {
            Resize-Partition -DriveLetter $dL -Size $dMax
        }
        Complete-Phase 10
    }

    Remove-Item $StatePath -Force -ErrorAction SilentlyContinue

    Step 'Done'
    Show-Layout $diskNo
    Get-Volume -DriveLetter $cL, $dL |
        Select-Object DriveLetter, FileSystemLabel,
            @{ n = 'SizeGB'; e = { ToGB $_.Size } },
            @{ n = 'FreeGB'; e = { ToGB $_.SizeRemaining } } |
        Format-Table -AutoSize | Out-Host
    if ([bool]$S.DonorEncrypted) {
        Say ('Reminder: the new ' + $dL + ': is not encrypted. Turn BitLocker / device encryption on for it again.') 'Yellow'
    }
    Say ('Logs: ' + $logDir)
}
catch {
    $exitCode = 1
    Write-Host ''
    Write-Host ('STOPPED: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host ''
    Write-Host ('Current state: ' + (Get-StateText $S)) -ForegroundColor Yellow
}
finally {
    if ($winReDisabled) {
        Write-Host ''
        Write-Host '==> Re-enabling Windows Recovery' -ForegroundColor Cyan
        try {
            & reagentc.exe /enable | Out-Host
            if (-not (Get-WinReInfo).Enabled) {
                Write-Host 'Windows Recovery is still disabled. Run "reagentc /enable" again after a reboot.' -ForegroundColor Yellow
            } elseif ($S -and (Test-Path $StatePath)) {
                $S.WinReDisabled = $false
                try { Save-State $S $StatePath } catch { }
            }
        } catch {
            Write-Host ('Could not re-enable Windows Recovery: ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    if ($bitLockerSuspended) {
        try {
            Resume-BitLocker -MountPoint ($cL + ':') | Out-Null
            Write-Host ('BitLocker on ' + $cL + ': resumed.')
            if ($S -and (Test-Path $StatePath)) {
                $S.BitLockerSuspended = $false
                try { Save-State $S $StatePath } catch { }
            }
        } catch {
            Write-Host ('Could not resume BitLocker on ' + $cL + ': - run:  Resume-BitLocker -MountPoint ' + $cL + ':') -ForegroundColor Yellow
        }
    }
    if ($shellSvcStopped) {
        try { Start-Service -Name ShellHWDetection } catch { }
    }
    if ($transcriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

exit $exitCode
