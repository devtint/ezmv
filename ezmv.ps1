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

.PARAMETER StagingPath
    Keep the temporary copy of the files in this folder (on another NTFS
    drive, for example an external disk) instead of on a temporary partition.
    The data drive then only has to hold its files once, so it can be more
    than half full. The folder must be empty or not exist yet.

.PARAMETER FromFreeSpace
    For a disk where the space after the target drive is already free (for
    example you deleted D: and the recovery partition yourself). ezmv asks
    how much to add to the target, then builds:
        target (+ your GB) | hidden recovery partition (1 GB) | new data drive
    No files are copied. A recovery partition further along the disk (often
    the manufacturer's) is left alone.

.PARAMETER DataLetter
    With -FromFreeSpace: drive letter for the new data drive. Default: D, or
    the next free letter.

.PARAMETER DataLabel
    With -FromFreeSpace: name for the new data drive. Default: Data.

.PARAMETER NoRecoveryPartition
    When the partition Windows Recovery lives on is removed, ezmv normally
    creates a new, hidden recovery partition (at least 1 GB) right after the
    target drive and moves Windows Recovery onto it. With this switch Windows
    Recovery stays on the Windows drive instead.

.PARAMETER StopAfterPhase
    Testing only: stop after the given step (1-9) to simulate an interruption.

.PARAMETER KillAt
    Testing only: kill the process at a named point inside a step
    (after-temp-created, after-donor-deleted), like a power cut.

.PARAMETER KillAfterPhase
    Testing only: kill the process right after the given step (1-9) is saved,
    skipping every clean-up, like a power cut.

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
    [string]$StagingPath,
    [switch]$NoRecoveryPartition,
    [switch]$FromFreeSpace,
    [string]$DataLetter,
    [string]$DataLabel = 'Data',
    [int]$StopAfterPhase = 0,
    [int]$KillAfterPhase = 0,
    [string]$KillAt
)

$ErrorActionPreference = 'Stop'
$EzmvVersion = '0.11.0'
$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$TempLabel = 'ezmv-temp'
$RecoveryLabel = 'Windows RE tools'
$RecoveryMinSize = 1GB
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
        Ok         = ($bad.Count -eq 0 -and ($unread + $tree.Unreadable) -eq 0)
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
function Copy-Tree([string]$FromRoot, [string]$ToRoot, [string]$LogFile, [int64]$ExpectedBytes, [string]$ProgressLetter, [switch]$Mirror) {
    $ex = Get-ExcludeDirs $FromRoot
    $src = Get-RoboPath $FromRoot
    $dst = Get-RoboPath $ToRoot
    if ($src -notmatch '\\$') { $src = '"' + $src + '"' }
    if ($dst -notmatch '\\$') { $dst = '"' + $dst + '"' }
    $argLine = ('{0} {1} /E {2} /DCOPY:DAT /XJ /R:1 /W:1 /NP /NFL /NDL "/LOG:{3}" /XD "{4}" "{5}"' -f $src, $dst, ($script:RoboCopyFlags -join ' '), $LogFile, $ex[0], $ex[1])
    # mirror: also remove files from the copy that were deleted from the
    # source; the system folders are excluded by name so they are never purged
    if ($Mirror) { $argLine += ' /PURGE /XD "System Volume Information" "$RECYCLE.BIN"' }
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

# Runs diskpart commands through standard input. No script file is written,
# so nothing a normal user can reach is ever executed with admin rights.
function Invoke-DiskPart([string[]]$Lines) {
    $text = (@($Lines) + 'exit') -join "`r`n"
    return ($text | & diskpart.exe | Out-String)
}

# GPT partition GUID as a lower-case string, or '' if there is none.
function Get-PartGuid($Partition) {
    if (-not $Partition) { return '' }
    return "$($Partition.Guid)".Trim().ToLower()
}

# Deletes the partition at an exact offset. When ExpectGuid is given, the
# partition there must still be the one ezmv recorded, or nothing is deleted.
function Remove-PartitionAtOffset([int]$DiskNumber, [int64]$Offset, [string]$ExpectGuid = '', [string]$ExpectType = '') {
    $p = Get-Layout $DiskNumber | Where-Object { [int64]$_.Offset -eq $Offset }
    if (-not $p) { return }
    if ($ExpectGuid -and (Get-PartGuid $p) -ne $ExpectGuid.Trim().ToLower()) {
        throw ('The partition at offset ' + (ToGB $Offset) + ' GB is not the one ezmv recorded (its GUID changed). Nothing was deleted. Stopping to be safe.')
    }
    if ($ExpectType -and "$($p.GptType)".ToLower() -ne $ExpectType.ToLower()) {
        throw ('The partition at offset ' + (ToGB $Offset) + ' GB is no longer of the expected type. Nothing was deleted. Stopping to be safe.')
    }
    try {
        Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
    } catch {
        Say ('  Remove-Partition refused, retrying with diskpart: ' + $_.Exception.Message) 'Yellow'
        Invoke-DiskPart @(('select disk ' + $DiskNumber), ('select partition ' + $p.PartitionNumber), 'delete partition override') | Out-Host
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

# Creates (or finishes, after an interruption) a hidden Windows recovery
# partition at an exact offset: NTFS, recovery GPT type, and the attributes
# "required" + "no drive letter", the same way Windows Setup makes it.
function New-RecoveryPartition([int]$DiskNumber, [int64]$Offset, [int64]$Size) {
    $p = Get-Layout $DiskNumber | Where-Object { [int64]$_.Offset -eq $Offset }
    if (-not $p) {
        $p = New-Partition -DiskNumber $DiskNumber -Offset $Offset -Size $Size
        if ([int64]$p.Offset -ne $Offset) {
            Remove-Partition -DiskNumber $DiskNumber -PartitionNumber $p.PartitionNumber -Confirm:$false
            throw ('The recovery partition landed in an unexpected place (offset ' + (ToGB $p.Offset) + ' GB). It was removed again.')
        }
        Start-Sleep -Seconds 2
    }
    # Every run reconciles all of it, so a run interrupted half way through
    # (for example type set but attributes not yet) is finished properly.
    $isRec = ("$($p.GptType)".ToLower() -eq $RecoveryGptType)
    if (-not $isRec) {
        $fs = ''
        try { $fs = "$((Get-Volume -Partition $p -ErrorAction Stop).FileSystem)" } catch { }
        if ($fs -ne 'NTFS') {
            Format-Volume -Partition $p -FileSystem NTFS -NewFileSystemLabel $RecoveryLabel -Confirm:$false | Out-Null
            Start-Sleep -Seconds 1
        }
    }
    $cmds = @(('select disk ' + $DiskNumber), ('select partition ' + $p.PartitionNumber))
    if (-not $isRec) { $cmds += ('set id=' + $RecoveryGptType.Trim('{}') + ' override') }
    if ((Get-GptAttributes $DiskNumber ([int]$p.PartitionNumber)) -ne '8000000000000001') { $cmds += 'gpt attributes=0x8000000000000001' }
    if ($cmds.Count -gt 2) { Invoke-DiskPart $cmds | Out-Null }
    Update-HostStorageCache
    $p = Get-Layout $DiskNumber | Where-Object { [int64]$_.Offset -eq $Offset }
    if (-not $p -or "$($p.GptType)".ToLower() -ne $RecoveryGptType) { throw 'Could not mark the new partition as a recovery partition.' }
    $attr = Get-GptAttributes $DiskNumber ([int]$p.PartitionNumber)
    if ($attr -ne '8000000000000001') {
        throw ('The recovery partition attributes are ' + $attr + ' instead of 8000000000000001 (required, no drive letter). Start ezmv again to retry.')
    }
    return $p
}

# GPT attributes of a partition as a hex string (for example 8000000000000001),
# read from diskpart because Get-Partition does not show them all.
function Get-GptAttributes([int]$DiskNumber, [int]$PartitionNumber) {
    $out = Invoke-DiskPart @(('select disk ' + $DiskNumber), ('select partition ' + $PartitionNumber), 'detail partition')
    if ($out -match 'Attrib\s*:\s*0[xX]([0-9A-Fa-f]+)') { return $Matches[1].ToUpper().PadLeft(16, '0') }
    return ''
}

# Deletes a folder tree, including files whose permissions deny access (backup
# mode) and paths longer than 260 characters. Returns $true when it is gone.
# No shell is involved, so names like %USERNAME% are never expanded, and a
# folder that is (or sits under) a link is refused instead of followed.
function Remove-Folder([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return $true }
    if (Test-ReparseOnPath $Path) { return $false }
    $empty = Join-Path $env:TEMP ('ezmv-empty-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $empty | Out-Null
    & robocopy.exe $empty $Path /MIR /XJ /B /R:0 /W:0 /NJH /NJS /NFL /NDL /NP | Out-Null
    Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
    try { [System.IO.Directory]::Delete(('\\?\' + $Path.TrimEnd('\')), $true) } catch { }
    return (-not (Test-Path -LiteralPath $Path))
}

# True when the path itself or any folder above it is a junction, symbolic
# link or mount point (so it may really live on another drive).
function Test-ReparseOnPath([string]$Path) {
    $p = $Path.TrimEnd('\')
    while ($p -and $p.Length -gt 3) {
        if (Test-Path -LiteralPath $p) {
            $a = [System.IO.File]::GetAttributes($p)
            if ($a -band [System.IO.FileAttributes]::ReparsePoint) { return $true }
        }
        $p = Split-Path $p -Parent
    }
    return $false
}

# Total size of all files in a copy (what the new data drive must hold).
function Get-TreeBytes([string]$Root) {
    $t = Get-Tree $Root
    [int64]$sum = 0
    foreach ($rel in $t.Files) {
        try { $sum += (New-Object System.IO.FileInfo($t.Base + '\' + $rel)).Length } catch { }
    }
    return $sum
}

# Where the Windows Recovery image is kept while Recovery is disabled.
function Get-WinReImagePath {
    if ($global:EzmvWinReImage) { return $global:EzmvWinReImage }   # tests
    return (Join-Path $env:SystemRoot 'System32\Recovery\Winre.wim')
}

# Where the temporary copy lives: a folder (with -StagingPath) or the
# temporary drive.
function Get-CopyName($State) {
    if ("$($State.StagingPath)") { return "$($State.StagingPath)" }
    return ("$($State.TempLetter)" + ':')
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
    if ("$($State.Mode)" -eq 'FromFree') {
        if ([int]$State.Phase -ge 10) { return 'The disk work is complete.' }
        return ('Step ' + $State.Phase + ' of 3 finished. No files are involved. Start ezmv again to finish the new layout.')
    }
    $d = $State.DonorLetter + ':'
    $t = Get-CopyName $State
    $c = $State.TargetLetter + ':'
    $again = ' Start ezmv again to continue or to roll back.'
    $staged = [bool]"$($State.StagingPath)"
    switch ([int]$State.Phase) {
        0 { return 'Nothing on the disk was changed.' }
        1 {
            if ($staged) { return ('Nothing on the disk was changed. All files are still on ' + $d + '.' + $again) }
            return ($d + ' was shrunk, nothing else changed. All files are still on ' + $d + '.' + $again)
        }
        2 {
            if ($staged) { return ('All files are still on ' + $d + '. The staging folder ' + $t + ' is empty.' + $again) }
            return ('All files are still on ' + $d + '. ' + $t + ' is an empty temporary drive.' + $again)
        }
        3 {
            if ([bool]$State.DonorDeleting) { return ('The old ' + $d + ' may already be deleted. YOUR FILES ARE ON ' + $t + ' - do not delete ' + $t + '. Start ezmv again to continue.') }
            return ('All files are still on ' + $d + '. ' + $t + ' holds a verified copy.' + $again)
        }
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
    # never delete the copy unless the original data drive is still there
    Update-HostStorageCache
    $orig = Get-Partition -DriveLetter $State.DonorLetter -ErrorAction SilentlyContinue
    $origOk = ($orig -and [int]$orig.DiskNumber -eq $diskNo -and [int64]$orig.Offset -eq [int64]$State.DonorOffset)
    if ($origOk -and "$($State.DonorGuid)" -and (Get-PartGuid $orig) -ne "$($State.DonorGuid)".ToLower()) { $origOk = $false }
    if (-not $origOk) {
        throw ('Roll-back stopped: the original ' + $State.DonorLetter + ': is not where it was, so the copy on ' + (Get-CopyName $State) + ' is kept. Start ezmv again and choose to continue.')
    }
    if ("$($State.StagingPath)") {
        if (-not (Remove-Folder "$($State.StagingPath)")) { Say ('  Could not delete the staging folder ' + $State.StagingPath + '. Delete it yourself; your files are on ' + $State.DonorLetter + ':.') 'Yellow' }
    }
    if (-not "$($State.StagingPath)") {
        # The temporary partition may exist even when its offset was never
        # saved (power cut right after creating it): look in the space that
        # shrinking freed, which held nothing else.
        $lo = [int64]$State.DonorOffset + [int64]$State.DonorShrunk - 1MB
        $hi = [int64]$State.DonorOffset + [int64]$State.DonorSize
        foreach ($tp in @(Get-Layout $diskNo | Where-Object { [int64]$_.Offset -ge $lo -and [int64]$_.Offset -lt $hi })) {
            $l = Get-Letter $tp
            if ((-not $l) -or $l -eq "$($State.TempLetter)") {
                Remove-PartitionAtOffset $diskNo ([int64]$tp.Offset)
            }
        }
    }
    Update-HostStorageCache
    $max = [int64](Get-PartitionSupportedSize -DriveLetter $State.DonorLetter).SizeMax
    if ($max - [int64](Get-Partition -DriveLetter $State.DonorLetter).Size -ge 1MB) {
        Resize-Partition -DriveLetter $State.DonorLetter -Size $max
    }
    Update-HostStorageCache
    $now = [int64](Get-Partition -DriveLetter $State.DonorLetter).Size
    if ([math]::Abs($now - [int64]$State.DonorSize) -gt 16MB) {
        throw ('Roll-back did not fully restore ' + $State.DonorLetter + ': (it is ' + (ToGB $now) + ' GB, it was ' + (ToGB $State.DonorSize) + ' GB). Your files are on ' + $State.DonorLetter + ':. Check Disk Management.')
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

# Moves Windows Recovery off a partition that is about to be deleted. Fails
# closed: unless reagentc succeeded and the image is safely on the Windows
# drive, nothing more is deleted.
function Move-WinReOff([int]$DiskNumber, $Offsets) {
    $Offsets = @($Offsets | ForEach-Object { [int64]$_ })
    if ($Offsets.Count -eq 0) { return }
    $winRe = Get-WinReInfo
    $rePart = $null
    if ($winRe.Enabled -and $winRe.Disk -eq $DiskNumber) {
        $rePart = Get-Layout $DiskNumber | Where-Object { [int]$_.PartitionNumber -eq $winRe.Partition }
    }
    $wim = Get-WinReImagePath
    if ($rePart -and ($Offsets -contains [int64]$rePart.Offset)) {
        Step 'Moving Windows Recovery off the partition that will be removed (re-enabled at the end)'
        $S.WinReDisabled = $true
        Save-State $S $StatePath
        $script:winReDisabled = $true
        $global:LASTEXITCODE = 0
        & reagentc.exe /disable | Out-Host
        $rc = $LASTEXITCODE
        if ($rc -ne 0 -or (Get-WinReInfo).Enabled -or -not (Test-Path -LiteralPath $wim)) {
            throw ('Windows Recovery could not be moved off its partition (reagentc exit code ' + $rc + ', image on the Windows drive: ' + (Test-Path -LiteralPath $wim) + '). The recovery partition was not deleted. Check "reagentc /info", then start ezmv again.')
        }
    } elseif ([bool]$S.WinReDisabled -and -not (Test-Path -LiteralPath $wim)) {
        throw ('Windows Recovery was disabled by ezmv, but its image is not on the Windows drive (' + $wim + '). The recovery partition was not deleted. Check "reagentc /info", then start ezmv again.')
    }
}

function Complete-Phase([int]$Number) {
    $S.Phase = $Number
    Save-State $S $StatePath
    if ($KillAfterPhase -eq $Number) { Stop-Process -Id $PID -Force }
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
    if (-not $usingDefaultState) {
        # A custom resume file gets the same protection: its folder is locked
        # to Administrators and SYSTEM, so nobody can swap the file later.
        $sDir = Split-Path ([System.IO.Path]::GetFullPath($StatePath)) -Parent
        $sLeaf = Split-Path $StatePath -Leaf
        if (Test-Path -LiteralPath $sDir) {
            if (Test-ReparseOnPath $sDir) { throw ('The folder for the resume file (' + $sDir + ') is a link or mount point. Use a plain folder for -StatePath.') }
            if (-not (Test-TrustedOwner $sDir)) { throw ('The folder for the resume file (' + $sDir + ') is not owned by Administrators. Use a new folder for -StatePath.') }
            $other = @(Get-ChildItem -LiteralPath $sDir -Force | Where-Object { @($sLeaf, ($sLeaf + '.tmp'), 'logs') -notcontains $_.Name })
            if ($other.Count -gt 0) { throw ('The folder ' + $sDir + ' holds other files. ezmv locks the folder of its resume file to Administrators, so use an empty or new folder for -StatePath.') }
        } else {
            New-Item -ItemType Directory -Path $sDir -Force | Out-Null
        }
        Protect-AdminOnly $sDir
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
    if ($saved -and -not $PlanOnly) {
        # Clean-up an earlier run still owes (it may have died before doing
        # it). It happens in finally, whatever this run does next.
        $cL = "$($saved.TargetLetter)"
        if ([bool]$saved.BitLockerSuspended) { $bitLockerSuspended = $true }
        if ([bool]$saved.WinReDisabled) { $winReDisabled = $true }
    }
    if ($saved -and [int]$saved.Phase -ge 10) {
        if ($bitLockerSuspended -or $winReDisabled) {
            Step 'Finishing the clean-up of the last run'
            $S = $saved
            return
        }
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
        $saved = $null
    }
    if ($saved) {
        Step 'An unfinished run was found'
        Say ('  Started:  ' + $saved.Started)
        if ("$($saved.Mode)" -eq 'FromFree') {
            Say ('  Job:      add ' + (ToGB $saved.GiveBytes) + ' GB to ' + $saved.TargetLetter + ':, then recovery and ' + $saved.DonorLetter + ': in the free space')
            Say ('  Progress: step ' + $saved.Phase + ' of 3 finished')
        } else {
            Say ('  Job:      give ' + (ToGB $saved.GiveBytes) + ' GB from ' + $saved.DonorLetter + ': to ' + $saved.TargetLetter + ':')
            Say ('  Progress: step ' + $saved.Phase + ' of 10 finished')
        }
        Say ('  State:    ' + (Get-StateText $saved)) 'Yellow'
        if ($PlanOnly) { Say ''; Say 'PLAN ONLY mode: stopping here.' 'Yellow'; return }

        $sameDisk = $false
        try { $sameDisk = ("$((Get-Disk -Number ([int]$saved.DiskNumber)).Guid)" -eq "$($saved.DiskGuid)") } catch { }
        if (-not $sameDisk) { throw ('The saved run belongs to a disk that is not attached (or its number changed). Resume file: ' + $StatePath) }

        if (Ask-YesNo 'Continue this run?') {
            $S = $saved
        } elseif ("$($saved.Mode)" -eq 'FromFree') {
            Say '  Left as it is. Start ezmv again when you want to finish.' 'Yellow'
            return
        } elseif ([int]$saved.Phase -le 3 -and -not [bool]$saved.DonorDeleting) {
            if (Ask-YesNo ('Roll back instead (remove the temporary drive and grow ' + $saved.DonorLetter + ': back)?')) {
                Step 'Rolling back'
                Undo-Early $saved
                # marked done; the file is removed once clean-up has finished
                $saved.Phase = 10
                Save-State $saved $StatePath
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

    # ---- fresh run, -FromFreeSpace: target | free space ---------------------
    if (-not $S -and $FromFreeSpace) {
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
        $next = Get-Layout $diskNo | Where-Object { [int64]$_.Offset -gt [int64]$cPart.Offset } | Select-Object -First 1
        $freeEnd = [int64]$disk.Size - 1MB
        if ($next) { $freeEnd = [int64]$next.Offset }
        $free = FloorMB ($freeEnd - $cEnd)
        if ($free -lt 2GB) {
            throw ('There is no free space right after ' + $tLetterIn + ': (' + (ToGB $free) + ' GB). -FromFreeSpace needs the space after ' + $tLetterIn + ': to be unallocated. Without it, ezmv moves space from the drive after ' + $tLetterIn + ': instead.')
        }
        $after = 'the end of the disk'
        if ($next) { $after = 'partition ' + $next.PartitionNumber + ' (' + $next.Type + ', left untouched)' }
        Say ('Free space:    ' + (ToGB $free) + ' GB right after ' + $tLetterIn + ':, up to ' + $after)

        Step 'Running safety checks'
        $cBl = $null
        try { $cBl = Get-BitLockerVolume -MountPoint ($tLetterIn + ':') } catch { }
        $cProtected = ($cBl -and "$($cBl.ProtectionStatus)" -eq 'On')
        if ($cBl -and "$($cBl.VolumeStatus)" -like '*InProgress*') {
            throw ('BitLocker is still encrypting or decrypting ' + $tLetterIn + ': (' + $cBl.VolumeStatus + '). Wait until it has finished, then run ezmv again.')
        }
        if ($cProtected) { Say ('  BitLocker on ' + $tLetterIn + ': is ON -> suspended during the work, resumed at the end') } else { Say '  BitLocker: nothing to suspend' }

        # Windows Recovery: already healthy on a recovery partition on this disk?
        $winRe = Get-WinReInfo
        $reHome = $null
        if ($winRe.Enabled -and $winRe.Disk -eq $diskNo) {
            $reHome = Get-Layout $diskNo | Where-Object { [int]$_.PartitionNumber -eq $winRe.Partition -and "$($_.GptType)".ToLower() -eq $RecoveryGptType }
        }
        $recreate = $false
        $recSize = [int64]0
        if ($NoRecoveryPartition) {
            Say '  recovery partition: skipped (-NoRecoveryPartition)'
        } elseif ($reHome) {
            Say ('  Windows Recovery already lives on recovery partition ' + $reHome.PartitionNumber + ', which is healthy. No new one is needed.')
        } else {
            $recreate = $true
            $recSize = [int64]$RecoveryMinSize
            Say ('  a new hidden recovery partition (' + (ToGB $recSize) + ' GB) will be created right after ' + $tLetterIn + ':, and Windows Recovery moved onto it')
            if (-not $winRe.Enabled -and -not (Test-Path -LiteralPath (Get-WinReImagePath))) {
                Say '  The Windows Recovery image (Winre.wim) was not found on the Windows drive, so Recovery may not turn on. The partition is created anyway.' 'Yellow'
            }
        }

        if ($DataLetter) {
            $newLetter = $DataLetter.Trim().TrimEnd(':').ToUpper()
            if ($newLetter -notmatch '^[A-Z]$') { throw ('"' + $DataLetter + '" is not a drive letter.') }
        } else {
            $usedLetters = @(Get-Volume | ForEach-Object { "$($_.DriveLetter)".Trim([char]0).Trim() } | Where-Object { $_ })
            $usedLetters += @(Get-PSDrive -PSProvider FileSystem | ForEach-Object { $_.Name })
            $newLetter = $null
            foreach ($c in 'D', 'E', 'F', 'G', 'H', 'I', 'J', 'K', 'L', 'M', 'N', 'O', 'P', 'Q', 'R', 'S', 'T', 'U', 'V', 'W', 'X', 'Y', 'Z') {
                if ($usedLetters -notcontains $c) { $newLetter = $c; break }
            }
            if (-not $newLetter) { throw 'No free drive letter is available for the new data drive.' }
        }
        if (Get-Partition -DriveLetter $newLetter -ErrorAction SilentlyContinue) { throw ('Drive letter ' + $newLetter + ': is already in use. Choose another with -DataLetter.') }

        $maxGive = [int][math]::Floor(($free - $recSize - 1GB) / 1GB)
        if ($maxGive -lt 0) { throw 'The free space is too small for a recovery partition and a data drive.' }

        Step 'Your choices'
        $give = $GiveGB
        if ($give -lt 0 -or $give -gt $maxGive) { throw ('-GiveGB must be between 0 and ' + $maxGive + '.') }
        if (-not $Yes -and -not $PSBoundParameters.ContainsKey('GiveGB') -and -not $PlanOnly) {
            $give = -1
            while ($give -lt 0 -or $give -gt $maxGive) {
                $raw = (Read-Host ('How many GB to add to ' + $tLetterIn + ':? (0-' + $maxGive + ') [0]')).Trim()
                if (-not $raw) { $give = 0; break }
                $n = 0
                if ([int]::TryParse($raw, [ref]$n)) { $give = $n }
            }
        }
        $giveBytes = [int64]$give * 1GB
        $dataSize = $free - $giveBytes - $recSize

        Step 'Plan'
        if ($give -gt 0) { Say ('   1. Extend ' + $tLetterIn + ': from ' + (ToGB $cPart.Size) + ' GB to ' + (ToGB ([int64]$cPart.Size + $giveBytes)) + ' GB') } else { Say ('   1. (' + $tLetterIn + ': stays ' + (ToGB $cPart.Size) + ' GB)') }
        if ($recreate) { Say ('   2. Create a hidden recovery partition (' + (ToGB $recSize) + ' GB) and move Windows Recovery onto it') } else { Say '   2. (no new recovery partition)' }
        Say ('   3. Create ' + $newLetter + ': "' + $DataLabel + '" with the rest, about ' + (ToGB $dataSize) + ' GB')
        Say ''
        $resText = '  Result:  ' + $tLetterIn + ': ' + (ToGB ([int64]$cPart.Size + $giveBytes)) + ' GB'
        if ($recreate) { $resText += ' | Recovery ' + (ToGB $recSize) + ' GB (hidden)' }
        $resText += ' | ' + $newLetter + ': about ' + (ToGB $dataSize) + ' GB'
        Say $resText 'Green'

        if ($PlanOnly) { Say ''; Say 'PLAN ONLY mode: stopping here. Nothing was changed.' 'Yellow'; return }

        Step 'Before you confirm'
        if ($cProtected) {
            Say ('  - Save your BitLocker recovery key:  manage-bde -protectors -get ' + $tLetterIn + ':')
            if (-not (Ask-YesNo 'Do you have your BitLocker recovery key saved somewhere safe?')) { throw 'Stopped: save the recovery key first.' }
        }
        if (-not (Ask-Word 'Ready to change the disk.' 'YES')) { throw 'Stopped by you.' }

        $S = [pscustomobject]@{
            Version        = $EzmvVersion
            Mode           = 'FromFree'
            Started        = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
            Phase          = 0
            DiskNumber     = $diskNo
            DiskGuid       = "$($disk.Guid)"
            TargetLetter   = $tLetterIn
            TargetOrigSize = [int64]$cPart.Size
            TargetGuid     = (Get-PartGuid $cPart)
            DonorLetter    = $newLetter
            DonorLabel     = $DataLabel
            DonorEncrypted = $false
            FreeEnd        = [int64]$freeEnd
            AllocUnit      = [int64]0
            Used           = [int64]0
            GiveBytes      = $giveBytes
            TempLetter     = ''
            TempOffset     = [int64]0
            StagingPath    = ''
            RecreateRecovery = [bool]$recreate
            RecoverySize   = [int64]$recSize
            RecoveryOffset = [int64]0
            VerifyHash     = $false
            BitLockerSuspended = $false
            WinReDisabled  = $false
        }
        Save-State $S $StatePath
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
        if (-not $donor) { throw ('No data drive with a letter was found after ' + $tLetterIn + ': on the same disk. If the space after ' + $tLetterIn + ': is free, run ezmv with -FromFreeSpace.') }
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
            throw ('The disk already has ' + (ToGB $disk.LargestFreeExtent) + ' GB of unallocated space. If it is right after ' + $tLetterIn + ':, run ezmv with -FromFreeSpace to split it into ' + $tLetterIn + ':, a recovery partition and a data drive. Otherwise extend a drive into it first.')
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
        $need = CeilMB (([double]$used * 1.03) + 512MB)      # room the files need, with margin

        # A new recovery partition replaces the one Windows Recovery lived on.
        $recreate = ($winReBetween -and -not $NoRecoveryPartition)
        $recSize = [int64]0
        if ($recreate) {
            $recSize = [int64]$RecoveryMinSize
            foreach ($p in $between) { if ([int64]$p.Size -gt $recSize) { $recSize = [int64]$p.Size } }
            $recSize = CeilMB $recSize
            Say ('  a new hidden recovery partition (' + (ToGB $recSize) + ' GB) will be created right after ' + $tLetterIn + ':')
        }

        $staging = ''
        if ($StagingPath) {
            # a bare drive (E: or E:\) means a new ezmv-staging folder on it
            $raw = $StagingPath.Trim()
            if ($raw -match '^[A-Za-z]:\\?$') { $raw = $raw.Substring(0, 2) + '\ezmv-staging' }
            if ($raw -notmatch '^[A-Za-z]:\\') { throw ('-StagingPath must be a full folder path on a local drive, like E:\ezmv-staging.') }
            $staging = [System.IO.Path]::GetFullPath($raw).TrimEnd('\')
            if (Test-ReparseOnPath $staging) { throw ('The staging folder ' + $staging + ' is, or sits under, a junction, link or mount point, so it could really be on another drive. Use a plain folder.') }
            $sLetter = $staging.Substring(0, 1).ToUpper()
            if ($sLetter -eq $dLetter.ToUpper()) { throw ('The staging folder cannot be on ' + $dLetter + ':, which will be deleted and recreated.') }
            $sVol = Get-Volume -DriveLetter $sLetter -ErrorAction SilentlyContinue
            if (-not $sVol) { throw ('Drive ' + $sLetter + ': for the staging folder was not found.') }
            if ("$($sVol.FileSystem)" -ne 'NTFS') { throw ('The staging drive ' + $sLetter + ': is ' + $sVol.FileSystem + '. It must be NTFS, or file permissions, dates and large files are lost.') }
            if ((Test-Path -LiteralPath $staging) -and @(Get-ChildItem -LiteralPath $staging -Force).Count -gt 0) {
                throw ('The staging folder ' + $staging + ' is not empty. Choose an empty or new folder.')
            }
            if ([int64]$sVol.SizeRemaining -lt $need) {
                throw ('The staging drive ' + $sLetter + ': has ' + (ToGB $sVol.SizeRemaining) + ' GB free, but ' + (ToGB $need) + ' GB is needed.')
            }
            Say ('  staging folder: ' + $staging + ' (' + (ToGB $sVol.SizeRemaining) + ' GB free): ok')
            $dShrunk = $dSize
            $maxGive = [int][math]::Floor(($gap + $dSize - $need - $recSize) / 1GB) - 1
            if ($maxGive -lt 1) {
                throw ($dLetter + ': does not have enough room left for its own files after giving space away. Free up space on ' + $dLetter + ': first.')
            }
        } else {
            $support = Get-PartitionSupportedSize -DriveLetter $dLetter
            $dMin = [int64]$support.SizeMin
            $dShrunk = FloorMB ($dSize - $need)                  # data drive size after shrinking
            if ($dShrunk -lt $dMin) {
                throw ($dLetter + ': can only shrink to ' + (ToGB $dMin) + ' GB, but it must shrink to ' + (ToGB $dShrunk) + ' GB to make room for a temporary copy. Use -StagingPath to keep the copy on another drive instead, or free up / defragment ' + $dLetter + ':.')
            }
            $maxGive = [int][math]::Floor(($gap + $dShrunk - $need - $recSize) / 1GB) - 1
            if ($maxGive -lt 1) {
                throw ($dLetter + ': is too full for this method (the files must fit twice). Use -StagingPath to keep the copy on another drive, or free up space on ' + $dLetter + ':.')
            }
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
        $tempLetter = ''
        if (-not $staging) { $tempLetter = Get-FreeLetter }
        $copyName = $staging
        if (-not $staging) { $copyName = $tempLetter + ':' }
        $cNew = [int64]$cPart.Size + $giveBytes
        $dFinal = $dSize + $gap - $giveBytes - $recSize

        Step 'Plan'
        if ($staging) {
            Say ('   1. (no shrinking needed: the copy goes to ' + $staging + ')')
            Say ('   2. Create the staging folder ' + $staging)
        } else {
            Say ('   1. Shrink ' + $dLetter + ': from ' + (ToGB $dSize) + ' GB to ' + (ToGB $dShrunk) + ' GB')
            Say ('   2. Create temporary drive ' + $tempLetter + ': (' + (ToGB ($dSize - $dShrunk)) + ' GB)')
        }
        Say ('   3. Copy ' + (ToGB $used) + ' GB of files to ' + $copyName + ' and verify')
        Say ('   4. DELETE the old ' + $dLetter + ':') 'Yellow'
        if ($between.Count -gt 0) {
            Say ('   5. DELETE ' + $between.Count + ' recovery partition(s) between ' + $tLetterIn + ': and ' + $dLetter + ':') 'Yellow'
        } else {
            Say '   5. (no recovery partition to remove)'
        }
        Say ('   6. Extend ' + $tLetterIn + ': from ' + (ToGB $cPart.Size) + ' GB to ' + (ToGB $cNew) + ' GB')
        if ($recreate) {
            Say ('   7. Create a hidden recovery partition (' + (ToGB $recSize) + ' GB) after ' + $tLetterIn + ':, move Windows Recovery onto it, and create a new ' + $dLetter + ':')
        } else {
            Say ('   7. Create a new ' + $dLetter + ':')
        }
        Say ('   8. Copy the files back and verify')
        Say ('   9. Delete ' + $copyName)
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
            TargetGuid     = (Get-PartGuid $cPart)
            DonorGuid      = (Get-PartGuid $donor)
            BetweenGuids   = @($between | ForEach-Object { Get-PartGuid $_ })
            DonorDeleting  = $false
            TempGuid       = ''
            CopyBytes      = [int64]0
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
            StagingPath    = $staging
            RecreateRecovery = [bool]$recreate
            RecoverySize   = [int64]$recSize
            RecoveryOffset = [int64]0
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
    $stg = "$($S.StagingPath)"
    $copyName = Get-CopyName $S
    $copyRoot = $tL + ':\'
    $copyLetter = $tL
    if ($stg) { $copyRoot = $stg; $copyLetter = $stg.Substring(0, 1) }
    $used = [int64]$S.Used
    $doHash = ([bool]$S.VerifyHash -or [bool]$VerifyHash)

    # Resume files from 0.9.0 do not have these fields yet.
    foreach ($f in 'BitLockerSuspended', 'WinReDisabled', 'RecreateRecovery') {
        if (-not ($S.PSObject.Properties.Name -contains $f)) { $S | Add-Member -NotePropertyName $f -NotePropertyValue $false }
    }
    foreach ($f in 'RecoverySize', 'RecoveryOffset') {
        if (-not ($S.PSObject.Properties.Name -contains $f)) { $S | Add-Member -NotePropertyName $f -NotePropertyValue ([int64]0) }
    }
    if (-not ($S.PSObject.Properties.Name -contains 'StagingPath')) { $S | Add-Member -NotePropertyName 'StagingPath' -NotePropertyValue '' }
    foreach ($f in 'TargetGuid', 'DonorGuid', 'TempGuid') {
        if (-not ($S.PSObject.Properties.Name -contains $f)) { $S | Add-Member -NotePropertyName $f -NotePropertyValue '' }
    }
    if (-not ($S.PSObject.Properties.Name -contains 'BetweenGuids')) { $S | Add-Member -NotePropertyName 'BetweenGuids' -NotePropertyValue @() }
    if (-not ($S.PSObject.Properties.Name -contains 'DonorDeleting')) { $S | Add-Member -NotePropertyName 'DonorDeleting' -NotePropertyValue $false }
    if (-not ($S.PSObject.Properties.Name -contains 'CopyBytes')) { $S | Add-Member -NotePropertyName 'CopyBytes' -NotePropertyValue ([int64]0) }

    # The drive letters must still belong to the partitions ezmv started with.
    if ("$($S.TargetGuid)") {
        $tNow = Get-Partition -DriveLetter $cL -ErrorAction SilentlyContinue
        if (-not $tNow -or (Get-PartGuid $tNow) -ne "$($S.TargetGuid)".ToLower()) { throw ($cL + ': is not the partition ezmv started with (its GUID changed). Stopping to be safe.') }
    }
    if ("$($S.Mode)" -ne 'FromFree' -and [int]$S.Phase -lt 4 -and -not [bool]$S.DonorDeleting -and "$($S.DonorGuid)") {
        $dNow = Get-Partition -DriveLetter $dL -ErrorAction SilentlyContinue
        if (-not $dNow -or (Get-PartGuid $dNow) -ne "$($S.DonorGuid)".ToLower()) { throw ($dL + ': is not the partition ezmv started with (its GUID changed). Stopping to be safe.') }
    }

    # After step 3 the files may only exist in the staging folder: make sure
    # its drive is plugged in before going on.
    if ($stg -and [int]$S.Phase -ge 3 -and [int]$S.Phase -lt 9 -and -not (Test-Path -LiteralPath $stg)) {
        throw ('The staging folder ' + $stg + ' is not reachable. Plug its drive back in (with the same letter), then start ezmv again.')
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

    # ---- -FromFreeSpace: 3 steps, then skip the normal 10 -------------------
    if ("$($S.Mode)" -eq 'FromFree') {
        if ([int]$S.Phase -lt 1) {
            Step ('Step 1/3: extending ' + $cL + ':')
            Update-HostStorageCache
            $wanted = [int64]$S.TargetOrigSize + [int64]$S.GiveBytes
            if ([int64](Get-Partition -DriveLetter $cL).Size -lt ($wanted - 1MB)) { Resize-Partition -DriveLetter $cL -Size $wanted }
            Say ('  ' + $cL + ': is now ' + (ToGB (Get-Partition -DriveLetter $cL).Size) + ' GB') 'Green'
            Complete-Phase 1
        }
        $cNow = Get-Partition -DriveLetter $cL
        $dMinOffset = [int64]$cNow.Offset + [int64]$cNow.Size
        if ([int]$S.Phase -lt 2) {
            if ([bool]$S.RecreateRecovery) {
                Step ('Step 2/3: creating a hidden recovery partition after ' + $cL + ':')
                if ([int64]$S.RecoveryOffset -le 0) {
                    $S.RecoveryOffset = [int64](CeilMB $dMinOffset)
                    Save-State $S $StatePath
                }
                $rec = New-RecoveryPartition $diskNo ([int64]$S.RecoveryOffset) ([int64]$S.RecoverySize)
                Say ('  recovery partition ' + $rec.PartitionNumber + ' (' + (ToGB $rec.Size) + ' GB) is ready') 'Green'
                # disable now (if on) and enable at the end, so Windows Recovery
                # is placed on the new partition
                $S.WinReDisabled = $true
                Save-State $S $StatePath
                $winReDisabled = $true
                if ((Get-WinReInfo).Enabled) { & reagentc.exe /disable | Out-Host }
            } else {
                Step 'Step 2/3: no new recovery partition'
            }
            Complete-Phase 2
        }
        if ([bool]$S.RecreateRecovery -and [int64]$S.RecoveryOffset -gt 0) {
            $rec = Get-Layout $diskNo | Where-Object { [int64]$_.Offset -eq [int64]$S.RecoveryOffset }
            if ($rec) { $dMinOffset = [int64]$rec.Offset + [int64]$rec.Size }
        }
        if ([int]$S.Phase -lt 3) {
            Step ('Step 3/3: creating ' + $dL + ': "' + $S.DonorLabel + '"')
            $null = New-DataDrive $diskNo $dL $S.DonorLabel 0 $dMinOffset ([int64]$S.FreeEnd)
            Say ('  ' + $dL + ': is ' + (ToGB (Get-Partition -DriveLetter $dL).Size) + ' GB') 'Green'
            Complete-Phase 3
        }
        Complete-Phase 10
    }

    if ([int]$S.Phase -lt 1) {
        Step ('Step 1/10: shrinking ' + $dL + ':')
        if ($stg) {
            Say '  not needed with a staging folder'
        } elseif ([int64](Get-Partition -DriveLetter $dL).Size -gt [int64]$S.DonorShrunk) {
            Resize-Partition -DriveLetter $dL -Size ([int64]$S.DonorShrunk)
        }
        Complete-Phase 1
    }

    if ([int]$S.Phase -lt 2) {
        if ($stg) {
            Step ('Step 2/10: creating the staging folder ' + $stg)
            if (-not (Test-Path -LiteralPath $stg)) { New-Item -ItemType Directory -Path $stg -Force | Out-Null }
            if ([int64](Get-Volume -DriveLetter $copyLetter).SizeRemaining -le $used) { throw ('The staging drive is too small for the files on ' + $dL + ':.') }
        } else {
            Step ('Step 2/10: creating temporary drive ' + $tL + ':')
            $tPart = New-DataDrive $diskNo $tL $TempLabel ([int64]$S.AllocUnit) ([int64]$S.DonorOffset + [int64]$S.DonorShrunk) ([int64]$S.DonorOffset + [int64]$S.DonorSize)
            if ($KillAt -eq 'after-temp-created') { Stop-Process -Id $PID -Force }
            $S.TempOffset = [int64]$tPart.Offset
            $S.TempGuid = Get-PartGuid $tPart
            if ([int64](Get-Volume -DriveLetter $tL).SizeRemaining -le $used) { throw ('The temporary drive is too small for the files on ' + $dL + ':.') }
        }
        Complete-Phase 2
    }

    if ([int]$S.Phase -lt 3) {
        Step ('Step 3/10: copying ' + $dL + ': to ' + $copyName + ' (' + (ToGB $used) + ' GB, this can take a while)')
        $log = Join-Path $logDir ('copy_to_temp_' + $stamp + '.log')
        $code = Copy-Tree ($dL + ':\') $copyRoot $log $used $copyLetter
        if ($code -ge 8) { throw ('The copy reported failures (robocopy code ' + $code + '). See ' + $log) }
        # copying a drive root gives the destination folder the root's
        # hidden + system attributes; a staging folder should stay visible
        if ($stg) { try { [System.IO.File]::SetAttributes($stg, [System.IO.FileAttributes]::Directory) } catch { } }
        Say '  verifying...'
        $check = Test-TreeCopy ($dL + ':\') $copyRoot
        if (-not $check.Ok) {
            Say ('  ' + $check.Lines.Count + ' item(s) differ or are missing on ' + $copyName) 'Red'
            $check.Lines | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_.Trim()) 'Red' }
            throw 'Verification failed. Close programs that use the data drive, then start ezmv again.'
        }
        if ($doHash) {
            $h = Compare-TreeHash ($dL + ':\') $copyRoot
            if (-not $h.Ok) {
                $h.Mismatch | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_) 'Red' }
                throw ('Content check failed: ' + $h.Mismatch.Count + ' file(s) different, ' + $h.Unreadable + ' could not be read. Nothing was deleted.')
            }
            Say ('  content check: ' + $h.Count + ' files identical, ' + $h.Unreadable + ' could not be read') 'Green'
        }
        Say ('  Every file on ' + $dL + ': is present on ' + $copyName + ' with the same size and date.') 'Green'
        Complete-Phase 3
    }

    if ([int]$S.Phase -lt 4) {
        $old = Get-Layout $diskNo | Where-Object { [int64]$_.Offset -eq [int64]$S.DonorOffset }
        if ($old) {
            if ((Get-Letter $old) -ne $dL) { throw ('The partition at the old position of ' + $dL + ': is not ' + $dL + ': any more. Stopping to be safe.') }
            if (-not [bool]$S.DonorDeleting) {
                Say ''
                Say ('POINT OF NO RETURN: the old ' + $dL + ': will now be deleted. Your files will live only on ' + $copyName + ' until they are copied back.') 'Yellow'
                if ($stg) { Say ('Do not unplug the drive that holds ' + $stg + ' until ezmv has finished.') 'Yellow' }
                if (-not (Ask-Word ('Delete the old ' + $dL + ':?') 'DELETE')) {
                    $undoText = 'remove ' + $tL + ': and grow ' + $dL + ': back'
                    if ($stg) { $undoText = 'delete the staging folder' }
                    if (Ask-YesNo ('Roll back now (' + $undoText + ')?')) {
                        Step 'Rolling back'
                        Undo-Early $S
                        $S.Phase = 10
                        Save-State $S $StatePath
                        Say '  Rolled back. The disk is as it was before.' 'Green'
                        Show-Layout $diskNo
                        return
                    }
                    throw 'Stopped by you before deleting anything.'
                }
            }
            if ($stg -and (Test-ReparseOnPath $stg)) { throw ('The staging folder ' + $stg + ' is now behind a junction, link or mount point. Nothing was deleted. Stopping to be safe.') }

            # Bring the copy up to date with anything that changed on the data
            # drive since it was verified (also after a pause between runs).
            Step ('Final sync: copying anything that changed on ' + $dL + ': since the check')
            $log = Join-Path $logDir ('final_sync_' + $stamp + '.log')
            $code = Copy-Tree ($dL + ':\') $copyRoot $log 0 '' -Mirror
            if ($code -ge 8) { throw ('The final sync reported failures (robocopy code ' + $code + '). See ' + $log + '. Nothing was deleted.') }
            if ($stg) { try { [System.IO.File]::SetAttributes($stg, [System.IO.FileAttributes]::Directory) } catch { } }
            $check = Test-TreeCopy ($dL + ':\') $copyRoot
            if (-not $check.Ok) {
                $check.Lines | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_.Trim()) 'Red' }
                throw ('Files on ' + $dL + ': are still changing. Close every program that uses ' + $dL + ':, then start ezmv again. Nothing was deleted.')
            }
            if ($doHash) {
                $h = Compare-TreeHash ($dL + ':\') $copyRoot
                if (-not $h.Ok) { throw ('Content check before deleting failed: ' + $h.Mismatch.Count + ' different, ' + $h.Unreadable + ' unreadable. Nothing was deleted.') }
            }

            # The new data drive must hold the copy as it really is: hard links
            # and compressed files can take more room once copied.
            $copyBytes = Get-TreeBytes $copyRoot
            $S.CopyBytes = [int64]$copyBytes
            $cOff = [int64](Get-Partition -DriveLetter $cL).Offset
            $regionEnd = [int64]$S.TempOffset
            if ($stg) { $regionEnd = [int64]$S.DonorOffset + [int64]$S.DonorSize }
            $recRoom = [int64]0
            if ([bool]$S.RecreateRecovery) { $recRoom = [int64]$S.RecoverySize }
            $newD = $regionEnd - ($cOff + [int64]$S.TargetOrigSize + [int64]$S.GiveBytes) - $recRoom
            $needD = [int64]([double]$copyBytes * 1.03) + 256MB
            if ($newD -lt $needD) {
                throw ('The new ' + $dL + ': would be about ' + (ToGB $newD) + ' GB, but the copied files need ' + (ToGB $needD) + ' GB (hard links or compressed files grow when copied). Nothing was deleted. Start ezmv again, roll back, and give less space.')
            }

            Move-WinReOff $diskNo $S.BetweenOffsets

            $S.DonorDeleting = $true
            Save-State $S $StatePath
            Step ('Step 4/10: deleting the old ' + $dL + ':')
            Remove-PartitionAtOffset $diskNo ([int64]$S.DonorOffset) ([string]$S.DonorGuid)
        }
        if ($KillAt -eq 'after-donor-deleted') { Stop-Process -Id $PID -Force }
        Complete-Phase 4
    }

    if ([int]$S.Phase -lt 5) {
        $offsets = @($S.BetweenOffsets | ForEach-Object { [int64]$_ })
        if ($offsets.Count -gt 0) {
            Move-WinReOff $diskNo $offsets
            $guids = @($S.BetweenGuids)
            for ($i = 0; $i -lt $offsets.Count; $i++) {
                $o = $offsets[$i]
                $g = ''
                if ($guids.Count -gt $i) { $g = [string]$guids[$i] }
                Step ('Step 5/10: deleting recovery partition at ' + (ToGB $o) + ' GB')
                Remove-PartitionAtOffset $diskNo $o $g $RecoveryGptType
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
        $cNow = Get-Partition -DriveLetter $cL
        $dMinOffset = [int64]$cNow.Offset + [int64]$cNow.Size
        if ([bool]$S.RecreateRecovery) {
            Step ('Step 7/10: creating a hidden recovery partition after ' + $cL + ':')
            if ([int64]$S.RecoveryOffset -le 0) {
                $S.RecoveryOffset = [int64](CeilMB $dMinOffset)
                Save-State $S $StatePath
            }
            $rec = New-RecoveryPartition $diskNo ([int64]$S.RecoveryOffset) ([int64]$S.RecoverySize)
            Say ('  recovery partition ' + $rec.PartitionNumber + ' (' + (ToGB $rec.Size) + ' GB) is ready') 'Green'
            $dMinOffset = [int64]$rec.Offset + [int64]$rec.Size
            # Windows Recovery is moved onto it when it is enabled again at the
            # end. If an earlier, interrupted run already re-enabled it on the
            # Windows drive, disable it again so it moves.
            if ((Get-WinReInfo).Enabled) {
                $S.WinReDisabled = $true
                Save-State $S $StatePath
                $winReDisabled = $true
                & reagentc.exe /disable | Out-Host
            }
        }
        Step ('Step 7/10: creating the new ' + $dL + ':')
        $dMaxOffset = [int64]$S.TempOffset - 1
        if ($stg) { $dMaxOffset = [int64]$S.DonorOffset + [int64]$S.DonorSize }
        $null = New-DataDrive $diskNo $dL $S.DonorLabel ([int64]$S.AllocUnit) $dMinOffset $dMaxOffset
        $mustHold = [math]::Max([int64]$used, [int64]$S.CopyBytes)
        if ([int64](Get-Volume -DriveLetter $dL).SizeRemaining -le $mustHold) { throw ('The new ' + $dL + ': is too small for the files. They are safe on ' + $copyName + '.') }
        Complete-Phase 7
    }

    if ([int]$S.Phase -lt 8) {
        Step ('Step 8/10: copying ' + $copyName + ' back to ' + $dL + ':')
        $log = Join-Path $logDir ('copy_back_' + $stamp + '.log')
        $code = Copy-Tree $copyRoot ($dL + ':\') $log $used $dL
        if ($code -ge 8) { throw ('The copy back reported failures (robocopy code ' + $code + '). See ' + $log + '. Your files are safe on ' + $copyName + '.') }
        Say '  verifying...'
        $check = Test-TreeCopy $copyRoot ($dL + ':\')
        if (-not $check.Ok) {
            Say ('  ' + $check.Lines.Count + ' item(s) differ or are missing on ' + $dL + ':') 'Red'
            $check.Lines | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_.Trim()) 'Red' }
            throw ('Verification failed. Your files are safe on ' + $copyName + '. Start ezmv again to retry.')
        }
        if ($doHash) {
            $h = Compare-TreeHash $copyRoot ($dL + ':\')
            if (-not $h.Ok) {
                $h.Mismatch | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_) 'Red' }
                throw ('Content check failed: ' + $h.Mismatch.Count + ' file(s) different, ' + $h.Unreadable + ' could not be read. Your files are safe on ' + $copyName + '.')
            }
            Say ('  content check: ' + $h.Count + ' files identical, ' + $h.Unreadable + ' could not be read') 'Green'
        }
        Say ('  Every file is back on ' + $dL + ':.') 'Green'
        Complete-Phase 8
    }

    if ([int]$S.Phase -lt 9) {
        # Check the data drive against the copy again right before the copy is
        # deleted: something may have changed it since step 8 (also between runs).
        $copyThere = $false
        if ($stg) {
            $copyThere = (Test-Path -LiteralPath $stg)
        } else {
            $tp0 = Get-Layout $diskNo | Where-Object { [int64]$_.Offset -eq [int64]$S.TempOffset }
            $copyThere = ($tp0 -and (Get-Letter $tp0) -eq $tL)
        }
        if ($copyThere) {
            Say ('  checking ' + $dL + ': against ' + $copyName + ' once more before deleting the copy...')
            $check = Test-TreeCopy $copyRoot ($dL + ':\')
            if (-not $check.Ok) {
                $check.Lines | Select-Object -First 20 | ForEach-Object { Say ('    ' + $_.Trim()) 'Red' }
                throw ('Files on ' + $dL + ': no longer match the copy on ' + $copyName + ', so the copy was NOT deleted. Start ezmv again after copying them back, or, if the changes on ' + $dL + ': are on purpose, delete ' + $copyName + ' yourself and start ezmv again to finish.')
            }
            if ($doHash) {
                $h = Compare-TreeHash $copyRoot ($dL + ':\')
                if (-not $h.Ok) { throw ('Content check failed: ' + $h.Mismatch.Count + ' different, ' + $h.Unreadable + ' unreadable. The copy on ' + $copyName + ' was NOT deleted.') }
            }
        }
        if ($stg) {
            if (-not (Ask-YesNo ('Delete the staging folder ' + $stg + '? Your files are now on ' + $dL + ':.'))) { throw 'Stopped by you.' }
            Step ('Step 9/10: deleting ' + $stg)
            if (-not (Remove-Folder $stg)) { Say ('  Could not delete ' + $stg + ' completely. Your files are on ' + $dL + ':, so you can delete it yourself.') 'Yellow' }
        } else {
            if (-not (Ask-YesNo ('Delete the temporary drive ' + $tL + ': and give its space back to ' + $dL + ':?'))) { throw 'Stopped by you.' }
            Step ('Step 9/10: deleting ' + $tL + ':')
            $tp = Get-Layout $diskNo | Where-Object { [int64]$_.Offset -eq [int64]$S.TempOffset }
            if ($tp -and (Get-Letter $tp) -ne $tL) { throw ('The partition at the position of ' + $tL + ': is not ' + $tL + ': any more. Stopping to be safe.') }
            Remove-PartitionAtOffset $diskNo ([int64]$S.TempOffset) ([string]$S.TempGuid)
        }
        Complete-Phase 9
    }

    if ([int]$S.Phase -lt 10) {
        Step ('Step 10/10: growing ' + $dL + ':')
        Update-HostStorageCache
        $dMax = [int64](Get-PartitionSupportedSize -DriveLetter $dL).SizeMax
        if ($dMax - [int64](Get-Partition -DriveLetter $dL).Size -ge 1MB) {
            Resize-Partition -DriveLetter $dL -Size $dMax
        }
        Complete-Phase 10
    }

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
    $shown = $S
    if (-not $shown) { $shown = $saved }
    Write-Host ('Current state: ' + (Get-StateText $shown)) -ForegroundColor Yellow
}
finally {
    $cs = $S
    if (-not $cs) { $cs = $saved }
    if ($winReDisabled) {
        Write-Host ''
        Write-Host '==> Re-enabling Windows Recovery' -ForegroundColor Cyan
        try {
            & reagentc.exe /enable | Out-Host
            $reNow = Get-WinReInfo
            if (-not $reNow.Enabled) {
                Write-Host 'Windows Recovery is still disabled. Run "reagentc /enable" again after a reboot.' -ForegroundColor Yellow
            } else {
                if ($cs -and [bool]$cs.RecreateRecovery -and [int64]$cs.RecoveryOffset -gt 0 -and [int]$cs.Phase -ge 7) {
                    $recP = Get-Layout ([int]$cs.DiskNumber) | Where-Object { [int64]$_.Offset -eq [int64]$cs.RecoveryOffset }
                    if ($recP -and $reNow.Disk -eq [int]$cs.DiskNumber -and $reNow.Partition -eq [int]$recP.PartitionNumber) {
                        Write-Host ('Windows Recovery is enabled on the new recovery partition (partition ' + $recP.PartitionNumber + ').') -ForegroundColor Green
                    } else {
                        Write-Host 'Windows Recovery is enabled, but not on the new recovery partition. To move it there, run "reagentc /disable" and then "reagentc /enable".' -ForegroundColor Yellow
                    }
                }
                if ($cs -and (Test-Path $StatePath)) {
                    $cs.WinReDisabled = $false
                    try { Save-State $cs $StatePath } catch { }
                }
            }
        } catch {
            Write-Host ('Could not re-enable Windows Recovery: ' + $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    if ($bitLockerSuspended) {
        try {
            Resume-BitLocker -MountPoint ($cL + ':') | Out-Null
            Write-Host ('BitLocker on ' + $cL + ': resumed.')
            if ($cs -and (Test-Path $StatePath)) {
                $cs.BitLockerSuspended = $false
                try { Save-State $cs $StatePath } catch { }
            }
        } catch {
            Write-Host ('Could not resume BitLocker on ' + $cL + ': - run:  Resume-BitLocker -MountPoint ' + $cL + ':') -ForegroundColor Yellow
        }
    }
    if ($shellSvcStopped) {
        try { Start-Service -Name ShellHWDetection } catch { }
    }
    # The resume file goes only when the disk work is done AND nothing is
    # left to restore, so a failed clean-up is retried by the next run.
    if ($cs -and [int]$cs.Phase -ge 10 -and -not [bool]$cs.BitLockerSuspended -and -not [bool]$cs.WinReDisabled) {
        Remove-Item $StatePath -Force -ErrorAction SilentlyContinue
    } elseif ($cs -and [int]$cs.Phase -ge 10) {
        Write-Host ('Some clean-up is still pending. Start ezmv again to finish it. Resume file: ' + $StatePath) -ForegroundColor Yellow
    }
    if ($transcriptOn) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

exit $exitCode
