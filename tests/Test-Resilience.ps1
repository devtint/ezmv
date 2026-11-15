#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Tests what happens when ezmv is killed mid-run (like a power cut), and that
    it refuses a resume file someone else planted.

.DESCRIPTION
    BitLocker and Windows Recovery are replaced by fakes (tests\fakes\Fakes.ps1)
    that keep their state in a file, so this runs on machines without
    BitLocker, such as GitHub's runners. The disk work is real and happens on a
    throw-away virtual disk, never on your real disks.

      A. Planted resume file: a resume file, and a default ezmv folder, owned
         by a normal user must be refused before anything happens.
      B. Killed right after the temporary drive was created (before its
         position was saved), then rolled back: the temporary drive must be
         found and removed, BitLocker resumed, and the disk as before.
      B2. Files changed after the copy was checked, then killed right after
         D: was deleted (before that was saved): the change must be in the
         copy, roll-back must not be offered, and the run must finish.
      C. reagentc /disable fails: nothing is deleted. Then killed after step 8,
         a restored file damaged: the copy must not be deleted. Then killed
         after step 10 before clean-up: the next run must resume BitLocker.
         The run must finish, resume BitLocker,
         create a hidden recovery partition right after the target and move
         Windows Recovery onto it.
      D. Data drive more than half full: refused without -StagingPath, and
         done with it (killed after step 5 and resumed).
      E. Data drive and recovery partition deleted by hand, only free space
         after the target: -FromFreeSpace builds target | recovery | data
         (killed after step 2 and resumed).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\Test-Resilience.ps1
#>
param(
    [string]$WorkDir = (Join-Path $env:TEMP 'ezmv-resilience-test'),
    [switch]$KeepDisk
)
$ErrorActionPreference = 'Stop'
$ezmv = Join-Path (Split-Path $PSScriptRoot -Parent) 'ezmv.ps1'
$fakes = Join-Path $PSScriptRoot 'fakes\Fakes.ps1'
. $ezmv

$script:Failed = 0
function Check([string]$Name, [bool]$Condition) {
    if ($Condition) {
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    } else {
        Write-Host ('  FAIL  ' + $Name) -ForegroundColor Red
        $script:Failed++
    }
}

$recoveryType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$vhd = Join-Path $WorkDir 'ezmv-resilience.vhd'
$statePath = Join-Path $WorkDir 'state\state.json'
$fakePath = Join-Path $WorkDir 'fake.json'
$mounted = $false
$testUser = 'ezmvtest' + (Get-Random -Maximum 9999)
$userMade = $false
$defaultDir = Join-Path $env:ProgramData 'ezmv'
$defaultAside = $defaultDir + '.before-test'

# Runs ezmv in a fresh PowerShell process with the fakes loaded. Returns the
# exit code and everything ezmv printed.
function Invoke-Ezmv([string[]]$EzmvArgs, [string]$Answers = '') {
    $env:EZMV_FAKE_STATE = $fakePath
    $env:EZMV_FAKE_ANSWERS = $Answers
    $quoted = @($EzmvArgs | ForEach-Object { if ($_ -like '-*') { $_ } else { "'" + $_.Replace("'", "''") + "'" } })
    $cmd = ". '" + $fakes + "'; `$global:LASTEXITCODE = 0; & '" + $ezmv + "' " + ($quoted -join ' ') + "; exit `$LASTEXITCODE"
    # ezmv's error output must not stop this test script, so it is collected
    # as text with errors set to Continue
    $ErrorActionPreference = 'Continue'
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $out | ForEach-Object { Write-Host ('    | ' + $_) -ForegroundColor DarkGray }
    return New-Object psobject -Property @{ Code = $code; Text = ($out -join "`n") }
}

function New-FakeState([string]$BitLockerLetter, [int]$WinReDisk, [int]$WinRePartition) {
    Remove-Item -LiteralPath (Join-Path $WorkDir 'Winre.wim') -Force -ErrorAction SilentlyContinue
    [pscustomobject]@{
        BitLockerLetter = $BitLockerLetter; BitLockerOn = $true
        WinReEnabled = $true; WinReDisk = $WinReDisk; WinRePartition = $WinRePartition
        Calls = @()
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fakePath -Encoding UTF8
}
function Get-FakeState { Get-Content -LiteralPath $fakePath -Raw | ConvertFrom-Json }

# The recovery partition ezmv creates must sit right after the target, be
# hidden, at least 1 GB, hold Windows Recovery, and be followed by the data drive.
function Test-NewRecovery([string]$Tag) {
    $t = Get-Partition -DriveLetter $tL
    $recs = @(Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType })
    Check ($Tag + ': exactly one recovery partition') ($recs.Count -eq 1)
    if ($recs.Count -ne 1) { return }
    $rec = $recs[0]
    $tEnd = [int64]$t.Offset + [int64]$t.Size
    Check ($Tag + ': it sits right after the target') (([int64]$rec.Offset - $tEnd) -ge 0 -and ([int64]$rec.Offset - $tEnd) -lt 1MB)
    Check ($Tag + ': it is at least 1 GB') ([int64]$rec.Size -ge 1GB)
    $attr = Get-GptAttributes $diskNo ([int]$rec.PartitionNumber)
    Check ($Tag + ': it has no drive letter') (-not (Get-Letter $rec))
    Check ($Tag + ': GPT attributes are required + no drive letter (' + $attr + ')') ($attr -eq '8000000000000001')
    $fs = ''
    try { $fs = "$((Get-Volume -Partition $rec -ErrorAction Stop).FileSystem)" } catch { }
    Check ($Tag + ': it is formatted NTFS') ($fs -eq 'NTFS')
    $f = Get-FakeState
    Check ($Tag + ': Windows Recovery is enabled on it') ($f.WinReEnabled -and [int]$f.WinReDisk -eq $diskNo -and [int]$f.WinRePartition -eq [int]$rec.PartitionNumber)
    $d = Get-Partition -DriveLetter $dL
    Check ($Tag + ': the data drive follows it') (([int64]$d.Offset - ([int64]$rec.Offset + [int64]$rec.Size)) -lt 1MB -and [int64]$d.Offset -gt [int64]$rec.Offset)
}

function Get-Manifest([string]$Letter) {
    $m = @{}
    $tree = Get-Tree ($Letter + ':\')
    foreach ($rel in $tree.Files) { $m[$rel] = Get-Sha256 ($tree.Base + '\' + $rel) }
    return $m
}
function Test-Manifest($Manifest, [string]$Letter) {
    foreach ($rel in $Manifest.Keys) {
        if ((Get-Sha256 ('\\?\' + $Letter + ':\' + $rel)) -ne $Manifest[$rel]) { return $false }
    }
    return ((Get-Tree ($Letter + ':\')).Files.Count -eq $Manifest.Count)
}

if (Test-Path $WorkDir) {
    try { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null } catch { }
    Remove-Item $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkDir | Out-Null

try {
    # ------------------------------------------------------------------ A --
    Write-Host ''
    Write-Host 'A. Planted resume file and folder' -ForegroundColor Cyan
    New-LocalUser -Name $testUser -NoPassword -Description 'ezmv test, safe to delete' | Out-Null
    $userMade = $true
    Check 'created a normal user to own the planted files' $userMade

    $planted = Join-Path $WorkDir 'planted\state.json'
    New-Item -ItemType Directory -Path (Split-Path $planted -Parent) | Out-Null
    Set-Content -Path $planted -Encoding UTF8 -Value '{"Phase":4,"DiskNumber":0,"DiskGuid":"x","TargetLetter":"C","DonorLetter":"D","TempLetter":"T","DonorOffset":1,"BetweenOffsets":[2]}'
    & icacls.exe $planted /setowner $testUser | Out-Null
    $r = Invoke-Ezmv @('-PlanOnly', '-Yes', '-StatePath', $planted)
    Check 'planted resume file: ezmv stops with an error' ($r.Code -eq 1)
    Check 'planted resume file: ezmv says it may have been tampered with' ($r.Text -like '*may have been tampered with*')
    Check 'planted resume file: ezmv did not act on it' ($r.Text -notlike '*unfinished run*')

    if (Test-Path $defaultDir) { Move-Item $defaultDir $defaultAside }
    New-Item -ItemType Directory -Path $defaultDir | Out-Null
    & icacls.exe $defaultDir /setowner $testUser | Out-Null
    $r = Invoke-Ezmv @('-PlanOnly', '-Yes')
    Check 'planted default folder: ezmv stops with an error' ($r.Code -eq 1)
    Check 'planted default folder: ezmv names the wrong owner' ($r.Text -like '*not by Administrators*')
    Remove-Item $defaultDir -Recurse -Force
    if (Test-Path $defaultAside) { Move-Item $defaultAside $defaultDir }

    # -------------------------------------------------------- virtual disk --
    Write-Host ''
    Write-Host 'Building the virtual disk' -ForegroundColor Cyan
    $dp = Join-Path $WorkDir 'create.txt'
    Set-Content -Path $dp -Encoding ASCII -Value ('create vdisk file="' + $vhd + '" maximum=12288 type=expandable')
    & diskpart.exe /s $dp | Out-Null
    if (-not (Test-Path $vhd)) { throw 'diskpart could not create the virtual disk.' }
    Mount-DiskImage -ImagePath $vhd -NoDriveLetter | Out-Null
    $mounted = $true
    $diskNo = [int](Get-DiskImage -ImagePath $vhd | Get-Disk).Number
    Initialize-Disk -Number $diskNo -PartitionStyle GPT
    $tL = Get-FreeLetter
    $tp = New-Partition -DiskNumber $diskNo -Size 2GB -DriveLetter $tL
    Format-Volume -Partition $tp -FileSystem NTFS -NewFileSystemLabel 'EZMV_TARGET' -Confirm:$false | Out-Null
    $rp = New-Partition -DiskNumber $diskNo -Size 200MB -GptType $recoveryType
    $dL = Get-FreeLetter
    $dpart = New-Partition -DiskNumber $diskNo -UseMaximumSize -DriveLetter $dL
    Format-Volume -Partition $dpart -FileSystem NTFS -NewFileSystemLabel 'EZMV_DATA' -Confirm:$false | Out-Null
    Start-Sleep -Seconds 2
    $rng = New-Object System.Random 11
    New-Item -ItemType Directory -Path ($dL + ':\docs') | Out-Null
    foreach ($i in 1..6) {
        $b = New-Object byte[] (2MB); $rng.NextBytes($b)
        [System.IO.File]::WriteAllBytes(($dL + ':\docs\file' + $i + '.bin'), $b)
    }
    $manifest = Get-Manifest $dL
    $targetBefore = [int64](Get-Partition -DriveLetter $tL).Size
    $dataBefore = [int64](Get-Partition -DriveLetter $dL).Size
    $partsBefore = @(Get-Partition -DiskNumber $diskNo).Count
    Write-Host ('  disk ' + $diskNo + ': target ' + $tL + ':  recovery partition ' + $rp.PartitionNumber + '  data ' + $dL + ':')

    # ------------------------------------------------------------------ B --
    Write-Host ''
    Write-Host 'B. Killed right after the temporary drive was created, then rolled back' -ForegroundColor Cyan
    New-FakeState $tL $diskNo ([int]$rp.PartitionNumber)
    $null = Invoke-Ezmv @('-Target', $tL, '-GiveGB', '1', '-Yes', '-StatePath', $statePath, '-KillAt', 'after-temp-created')
    $mid = Read-State $statePath
    $f = Get-FakeState
    Update-HostStorageCache
    Check 'killed run left the resume file at step 1, temporary position not saved' ($mid -and [int]$mid.Phase -eq 1 -and [int64]$mid.TempOffset -eq 0)
    Check 'the temporary drive exists anyway' ($mid -and [bool](Get-Partition -DriveLetter $mid.TempLetter -ErrorAction SilentlyContinue))
    Check 'resume file records that ezmv suspended BitLocker' ($mid -and [bool]$mid.BitLockerSuspended)
    Check 'BitLocker is left suspended by the kill (as after a power cut)' (-not $f.BitLockerOn)

    $r = Invoke-Ezmv @('-StatePath', $statePath) 'n,y'
    $f = Get-FakeState
    Update-HostStorageCache
    Check 'rollback run exits cleanly' ($r.Code -eq 0)
    Check 'rollback run resumed BitLocker' ($f.BitLockerOn -and (@($f.Calls) -contains ('Resume-BitLocker ' + $tL + ':')))
    Check 'resume file was removed' (-not (Test-Path $statePath))
    Check 'temporary drive is gone' (@(Get-Partition -DiskNumber $diskNo).Count -eq $partsBefore)
    Check 'data drive is back to its old size' ([math]::Abs([int64](Get-Partition -DriveLetter $dL).Size - $dataBefore) -le 16MB)
    Check 'files on the data drive are unchanged' (Test-Manifest $manifest $dL)
    Check 'Windows Recovery was never touched' ($f.WinReEnabled -and (@($f.Calls) -notcontains 'reagentc /disable'))

    # ----------------------------------------------------------------- B2 --
    Write-Host ''
    Write-Host 'B2. Change after the check, then killed right after deleting D:' -ForegroundColor Cyan
    New-FakeState $tL $diskNo ([int]$rp.PartitionNumber)
    $targetBefore = [int64](Get-Partition -DriveLetter $tL).Size
    $null = Invoke-Ezmv @('-Target', $tL, '-GiveGB', '1', '-Yes', '-StatePath', $statePath, '-KillAfterPhase', '3')
    $mid = Read-State $statePath
    Check 'killed run left the resume file at step 3' ($mid -and [int]$mid.Phase -eq 3)
    $tmpL = "$($mid.TempLetter)"

    # T: moved to another letter while paused: the final sync must not run
    $spare = $null
    foreach ($c in 'U', 'V', 'W', 'X', 'Y', 'Q', 'P', 'O') { if (-not (Get-Volume -DriveLetter $c -ErrorAction SilentlyContinue)) { $spare = $c; break } }
    Set-Partition -DriveLetter $tmpL -NewDriveLetter $spare
    $r = Invoke-Ezmv @('-Yes', '-StatePath', $statePath)
    Update-HostStorageCache
    Check 'a temporary drive under another letter stops the run before any sync' ($r.Code -eq 1 -and $r.Text -like '*is not the temporary drive*')
    Check 'nothing was deleted' ([bool](Get-Partition -DriveLetter $dL -ErrorAction SilentlyContinue) -and [int](Read-State $statePath).Phase -eq 3)
    Set-Partition -DriveLetter $spare -NewDriveLetter $tmpL

    Set-Content -Path ($dL + ':\docs\late.txt') -Value 'written after the copy was checked' -Encoding ASCII
    $manifest = Get-Manifest $dL

    $null = Invoke-Ezmv @('-Yes', '-StatePath', $statePath, '-KillAt', 'after-donor-deleted')
    $mid = Read-State $statePath
    Update-HostStorageCache
    Check 'killed run left step 3 with the deletion recorded' ($mid -and [int]$mid.Phase -eq 3 -and [bool]$mid.DonorDeleting)
    Check 'the old data drive is gone' (-not (Get-Partition -DriveLetter $dL -ErrorAction SilentlyContinue))
    Check 'the late change made it into the copy' (Test-Path ($tmpL + ':\docs\late.txt'))

    $r = Invoke-Ezmv @('-StatePath', $statePath) 'n'
    Update-HostStorageCache
    Check 'roll-back is not offered after the deletion' ($r.Text -like '*past the point*' -and $r.Text -notlike '*Roll back instead*')
    Check 'the temporary drive still holds the files' (Test-Path ($tmpL + ':\docs\late.txt'))

    # an empty new partition put where D: was must not become the sync source
    $fake = New-Partition -DiskNumber $diskNo -Offset ([int64]$mid.DonorOffset) -Size 512MB -DriveLetter $dL
    Format-Volume -Partition $fake -FileSystem NTFS -NewFileSystemLabel 'IMPOSTOR' -Confirm:$false | Out-Null
    $r = Invoke-Ezmv @('-Yes', '-StatePath', $statePath)
    Update-HostStorageCache
    Check 'a replacement partition at the old place of D: is refused' ($r.Code -eq 1 -and $r.Text -like '*is not the original*')
    Check 'the copy on the temporary drive is untouched' (Test-Path ($tmpL + ':\docs\late.txt'))
    Remove-Partition -DiskNumber $diskNo -PartitionNumber (Get-Partition -DriveLetter $dL).PartitionNumber -Confirm:$false
    Update-HostStorageCache

    $r = Invoke-Ezmv @('-Yes', '-StatePath', $statePath)
    Update-HostStorageCache
    Check 'the run finishes' ($r.Code -eq 0 -and -not (Test-Path $statePath))
    Check 'target grew by 1 GB' ([math]::Abs([int64](Get-Partition -DriveLetter $tL).Size - $targetBefore - 1GB) -le 1MB)
    Check 'files, including the late change, are on the new data drive' (Test-Manifest $manifest $dL)

    # ------------------------------------------------------------------ C --
    Write-Host ''
    Write-Host 'C. Recovery disable fails, damaged file after step 8, killed before clean-up' -ForegroundColor Cyan
    $rp = Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType }
    New-FakeState $tL $diskNo ([int]$rp.PartitionNumber)
    $targetBefore = [int64](Get-Partition -DriveLetter $tL).Size
    $env:EZMV_FAKE_FAIL_DISABLE = '1'
    $r = Invoke-Ezmv @('-Target', $tL, '-GiveGB', '1', '-Yes', '-StatePath', $statePath)
    $env:EZMV_FAKE_FAIL_DISABLE = ''
    Update-HostStorageCache
    $mid = Read-State $statePath
    Check 'failed reagentc /disable stops the run' ($r.Code -eq 1 -and $r.Text -like '*could not be moved off*')
    Check 'nothing was deleted (data drive and recovery partition still there)' ([bool](Get-Partition -DriveLetter $dL -ErrorAction SilentlyContinue) -and @(Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType }).Count -eq 1)
    Check 'BitLocker was resumed after the stop' ((Get-FakeState).BitLockerOn)

    $null = Invoke-Ezmv @('-Yes', '-StatePath', $statePath, '-KillAfterPhase', '8')
    $mid = Read-State $statePath
    $f = Get-FakeState
    Check 'killed run left the resume file at step 8' ($mid -and [int]$mid.Phase -eq 8)
    Check 'resume file records BitLocker suspended and Recovery disabled' ($mid -and [bool]$mid.BitLockerSuspended -and [bool]$mid.WinReDisabled)
    Check 'BitLocker and Windows Recovery are left off by the kill' ((-not $f.BitLockerOn) -and (-not $f.WinReEnabled))

    $tmpL = "$($mid.TempLetter)"
    $victim = Get-ChildItem -LiteralPath ($dL + ':\docs') -File | Select-Object -First 1
    [System.IO.File]::AppendAllText($victim.FullName, 'damage')
    $r = Invoke-Ezmv @('-Yes', '-StatePath', $statePath)
    Update-HostStorageCache
    Check 'a damaged restored file stops the run' ($r.Code -eq 1 -and $r.Text -like '*no longer match*')
    Check 'the copy was not deleted' (Test-Path ($tmpL + ':\docs\' + $victim.Name))
    Copy-Item -LiteralPath ($tmpL + ':\docs\' + $victim.Name) -Destination $victim.FullName -Force

    $null = Invoke-Ezmv @('-Yes', '-StatePath', $statePath, '-KillAfterPhase', '10')
    $mid = Read-State $statePath
    Check 'killed after step 10 with BitLocker still suspended' ($mid -and [int]$mid.Phase -eq 10 -and [bool]$mid.BitLockerSuspended -and -not (Get-FakeState).BitLockerOn)
    $null = Invoke-Ezmv @('-PlanOnly', '-StatePath', $statePath)
    Check '-PlanOnly keeps the resume file with the pending clean-up' ((Test-Path $statePath) -and [bool](Read-State $statePath).BitLockerSuspended)

    $r = Invoke-Ezmv @('-Yes', '-StatePath', $statePath)
    $f = Get-FakeState
    Update-HostStorageCache
    Check 'next run finishes the clean-up and exits cleanly' ($r.Code -eq 0 -and $r.Text -like '*Finishing the clean-up*')
    Check 'BitLocker is back on' ($f.BitLockerOn)
    Check 'Windows Recovery is enabled' ($f.WinReEnabled -and (@($f.Calls) -contains 'reagentc /enable'))
    Check 'resume file was removed' (-not (Test-Path $statePath))
    Check 'target grew by 1 GB' ([math]::Abs([int64](Get-Partition -DriveLetter $tL).Size - $targetBefore - 1GB) -le 1MB)
    Check 'files on the data drive are unchanged' (Test-Manifest $manifest $dL)
    Test-NewRecovery 'C'

    # ------------------------------------------------------------------ D --
    Write-Host ''
    Write-Host 'D. Data drive more than half full, with and without -StagingPath' -ForegroundColor Cyan
    $rp = Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType }
    New-FakeState '' $diskNo ([int]$rp.PartitionNumber)
    $jTarget = $dL + ':\ezmv-stage-target'
    New-Item -ItemType Directory -Path $jTarget | Out-Null
    $jLink = Join-Path $WorkDir 'staging-link'
    & cmd.exe /c mklink /J $jLink $jTarget | Out-Null
    $r = Invoke-Ezmv @('-Target', $tL, '-GiveGB', '1', '-Yes', '-PlanOnly', '-StagingPath', $jLink, '-StatePath', $statePath)
    Check 'a staging folder that is a junction onto D: is refused' ($r.Code -eq 1 -and $r.Text -like '*junction*')
    [System.IO.Directory]::Delete($jLink)
    Remove-Item -LiteralPath $jTarget -Force
    $dSizeNow = [int64](Get-Partition -DriveLetter $dL).Size
    $bigSize = [int64](FloorMB ($dSizeNow * 0.52))
    & fsutil.exe file createnew ($dL + ':\big.bin') $bigSize | Out-Null
    Write-Host ('  ' + $dL + ': is now ' + [int](100 * (Get-UsedBytes $dL) / $dSizeNow) + '% full')
    $manifest = Get-Manifest $dL
    $targetBefore = [int64](Get-Partition -DriveLetter $tL).Size

    $r = Invoke-Ezmv @('-Target', $tL, '-GiveGB', '1', '-Yes', '-PlanOnly', '-StatePath', $statePath)
    Check 'without -StagingPath ezmv refuses (files would not fit twice)' ($r.Code -eq 1 -and $r.Text -like '*-StagingPath*')

    $stg = Join-Path $WorkDir 'staging'
    $null = Invoke-Ezmv @('-Target', $tL, '-GiveGB', '1', '-Yes', '-StagingPath', $stg, '-StatePath', $statePath, '-KillAfterPhase', '5')
    $mid = Read-State $statePath
    Update-HostStorageCache
    Check 'killed run left the resume file at step 5' ($mid -and [int]$mid.Phase -eq 5)
    Check 'resume file remembers the staging folder' ($mid -and "$($mid.StagingPath)" -eq $stg)
    Check 'data drive is gone, files are in the staging folder' ((-not (Get-Partition -DriveLetter $dL -ErrorAction SilentlyContinue)) -and (Test-Path (Join-Path $stg 'big.bin')))
    Check 'staging folder is not hidden' (((Get-Item -LiteralPath $stg -Force).Attributes -band [System.IO.FileAttributes]::Hidden) -eq 0)

    $r = Invoke-Ezmv @('-Yes', '-StatePath', $statePath)
    Update-HostStorageCache
    Check 'resumed run exits cleanly' ($r.Code -eq 0)
    Check 'resume file was removed' (-not (Test-Path $statePath))
    Check 'staging folder was deleted' (-not (Test-Path -LiteralPath $stg))
    Check 'target grew by 1 GB' ([math]::Abs([int64](Get-Partition -DriveLetter $tL).Size - $targetBefore - 1GB) -le 1MB)
    Check 'files on the data drive are unchanged' (Test-Manifest $manifest $dL)
    Check 'no unallocated space left' ([int64](Get-Disk -Number $diskNo).LargestFreeExtent -le 16MB)
    Test-NewRecovery 'D'

    # ------------------------------------------------------------------ E --
    Write-Host ''
    Write-Host 'E. Only free space after the target, -FromFreeSpace' -ForegroundColor Cyan
    $d = Get-Partition -DriveLetter $dL
    Remove-Partition -DiskNumber $diskNo -PartitionNumber $d.PartitionNumber -Confirm:$false
    $rp = Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType }
    Remove-Partition -DiskNumber $diskNo -PartitionNumber $rp.PartitionNumber -Confirm:$false
    Update-HostStorageCache
    New-FakeState '' $diskNo 0
    $f = Get-FakeState; $f.WinReEnabled = $false; $f.WinRePartition = 0
    $f | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $fakePath -Encoding UTF8
    $targetBefore = [int64](Get-Partition -DriveLetter $tL).Size

    $r = Invoke-Ezmv @('-Target', $tL, '-Yes', '-PlanOnly', '-StatePath', $statePath)
    Check 'normal mode stops and suggests -FromFreeSpace' ($r.Code -eq 1 -and $r.Text -like '*-FromFreeSpace*')

    $null = Invoke-Ezmv @('-FromFreeSpace', '-Target', $tL, '-GiveGB', '1', '-DataLetter', $dL, '-DataLabel', 'EZMV_NEW', '-Yes', '-StatePath', $statePath, '-KillAfterPhase', '2')
    $mid = Read-State $statePath
    Check 'killed run left the resume file at step 2' ($mid -and [int]$mid.Phase -eq 2 -and "$($mid.Mode)" -eq 'FromFree')

    $r = Invoke-Ezmv @('-Yes', '-StatePath', $statePath)
    Update-HostStorageCache
    Check 'resumed run exits cleanly' ($r.Code -eq 0)
    Check 'resume file was removed' (-not (Test-Path $statePath))
    Check 'target grew by 1 GB' ([math]::Abs([int64](Get-Partition -DriveLetter $tL).Size - $targetBefore - 1GB) -le 1MB)
    Check 'new data drive has the chosen letter and name' ((Get-Partition -DriveLetter $dL -ErrorAction SilentlyContinue) -and (Get-Volume -DriveLetter $dL).FileSystemLabel -eq 'EZMV_NEW')
    Check 'no unallocated space left' ([int64](Get-Disk -Number $diskNo).LargestFreeExtent -le 16MB)
    Test-NewRecovery 'E'
}
catch {
    Write-Host ('TEST ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    $script:Failed++
}
finally {
    if ((Test-Path $defaultAside) -and -not (Test-Path $defaultDir)) { Move-Item $defaultAside $defaultDir }
    if ($userMade) { try { Remove-LocalUser -Name $testUser } catch { } }
    if ($mounted -and -not $KeepDisk) {
        try { Dismount-DiskImage -ImagePath $vhd | Out-Null } catch { }
        Start-Sleep -Seconds 1
        try { Remove-Item $WorkDir -Recurse -Force } catch { Write-Host ('cleanup: ' + $_.Exception.Message) -ForegroundColor Yellow }
    } elseif ($KeepDisk) {
        Write-Host ('Work folder kept: ' + $WorkDir)
    }
}

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host 'Resilience test passed.' -ForegroundColor Green
    exit 0
}
Write-Host ($script:Failed.ToString() + ' check(s) failed.') -ForegroundColor Red
exit 1
