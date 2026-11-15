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
      B. Killed after step 3 with BitLocker on, then rolled back: BitLocker must
         be resumed and the disk must be as before.
      C. Killed after step 5 with BitLocker on and Windows Recovery on the
         partition being removed: the resumed run must finish, resume BitLocker,
         create a hidden recovery partition right after the target and move
         Windows Recovery onto it.
      D. Data drive more than half full: refused without -StagingPath, and
         done with it (killed after step 5 and resumed).

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
    Set-Content -Path $dp -Encoding ASCII -Value ('create vdisk file="' + $vhd + '" maximum=10240 type=expandable')
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
    Write-Host 'B. Killed after step 3 with BitLocker on, then rolled back' -ForegroundColor Cyan
    New-FakeState $tL $diskNo ([int]$rp.PartitionNumber)
    $null = Invoke-Ezmv @('-Target', $tL, '-GiveGB', '1', '-Yes', '-StatePath', $statePath, '-KillAfterPhase', '3')
    $mid = Read-State $statePath
    $f = Get-FakeState
    Check 'killed run left the resume file at step 3' ($mid -and [int]$mid.Phase -eq 3)
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

    # ------------------------------------------------------------------ C --
    Write-Host ''
    Write-Host 'C. Killed after step 5 with BitLocker and Windows Recovery on, then resumed' -ForegroundColor Cyan
    $rp = Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType }
    New-FakeState $tL $diskNo ([int]$rp.PartitionNumber)
    $null = Invoke-Ezmv @('-Target', $tL, '-GiveGB', '1', '-Yes', '-StatePath', $statePath, '-KillAfterPhase', '5')
    $mid = Read-State $statePath
    $f = Get-FakeState
    Check 'killed run left the resume file at step 5' ($mid -and [int]$mid.Phase -eq 5)
    Check 'resume file records BitLocker suspended and Recovery disabled' ($mid -and [bool]$mid.BitLockerSuspended -and [bool]$mid.WinReDisabled)
    Check 'BitLocker and Windows Recovery are left off by the kill' ((-not $f.BitLockerOn) -and (-not $f.WinReEnabled))

    $r = Invoke-Ezmv @('-Yes', '-StatePath', $statePath)
    $f = Get-FakeState
    Update-HostStorageCache
    Check 'resumed run exits cleanly' ($r.Code -eq 0)
    Check 'resumed run resumed BitLocker' ($f.BitLockerOn)
    Check 'resumed run re-enabled Windows Recovery' ($f.WinReEnabled -and (@($f.Calls) -contains 'reagentc /enable'))
    Check 'BitLocker was suspended only once' (@(@($f.Calls) | Where-Object { $_ -like 'Suspend-BitLocker*' }).Count -eq 1)
    Check 'resume file was removed' (-not (Test-Path $statePath))
    Check 'target grew by 1 GB' ([math]::Abs([int64](Get-Partition -DriveLetter $tL).Size - $targetBefore - 1GB) -le 1MB)
    Check 'files on the data drive are unchanged' (Test-Manifest $manifest $dL)
    Test-NewRecovery 'C'

    # ------------------------------------------------------------------ D --
    Write-Host ''
    Write-Host 'D. Data drive more than half full, with and without -StagingPath' -ForegroundColor Cyan
    $rp = Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType }
    New-FakeState '' $diskNo ([int]$rp.PartitionNumber)
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
