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
         partition being removed: the resumed run must finish, resume BitLocker
         and re-enable Windows Recovery.

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
    $out = @(& powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $cmd 2>&1 | ForEach-Object { "$_" })
    $code = $LASTEXITCODE
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
    Set-Content -Path $dp -Encoding ASCII -Value ('create vdisk file="' + $vhd + '" maximum=6144 type=expandable')
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
    Check 'recovery partition was removed' (@(Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType }).Count -eq 0)
    Check 'files on the data drive are unchanged' (Test-Manifest $manifest $dL)
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
