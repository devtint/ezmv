#Requires -RunAsAdministrator
<#
.SYNOPSIS
    End-to-end test of ezmv on a throw-away virtual disk (VHD file).

.DESCRIPTION
    Builds an 8 GB virtual disk with the layout

        target | recovery | data (with test files)

    then runs ezmv against it twice: once interrupted after step 5 (the worst
    moment: files exist only on the temporary drive) and once more to resume.
    Afterwards it checks the partition sizes and the SHA-256 of every file.

    Your real disks are never selected: ezmv is pointed at the virtual disk
    with -Target, and uses its own resume file inside the test folder.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\Test-OnVirtualDisk.ps1
#>
param(
    [string]$WorkDir = (Join-Path $env:TEMP 'ezmv-vhd-test'),
    [switch]$KeepDisk
)
$ErrorActionPreference = 'Stop'
$ezmv = Join-Path (Split-Path $PSScriptRoot -Parent) 'ezmv.ps1'
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
$vhd = Join-Path $WorkDir 'ezmv-test.vhd'
$statePath = Join-Path $WorkDir 'state\state.json'
$mounted = $false

if (Test-Path $WorkDir) {
    try { Dismount-DiskImage -ImagePath $vhd -ErrorAction SilentlyContinue | Out-Null } catch { }
    Remove-Item $WorkDir -Recurse -Force
}
New-Item -ItemType Directory -Path $WorkDir | Out-Null

try {
    Write-Host ''
    Write-Host 'Building the virtual disk' -ForegroundColor Cyan
    $dp = Join-Path $WorkDir 'create.txt'
    Set-Content -Path $dp -Encoding ASCII -Value ('create vdisk file="' + $vhd + '" maximum=8192 type=expandable')
    & diskpart.exe /s $dp | Out-Null
    if (-not (Test-Path $vhd)) { throw 'diskpart could not create the virtual disk.' }
    Mount-DiskImage -ImagePath $vhd -NoDriveLetter | Out-Null
    $mounted = $true
    $diskNo = [int](Get-DiskImage -ImagePath $vhd | Get-Disk).Number
    Initialize-Disk -Number $diskNo -PartitionStyle GPT

    $tL = Get-FreeLetter
    $tp = New-Partition -DiskNumber $diskNo -Size 2GB -DriveLetter $tL
    Format-Volume -Partition $tp -FileSystem NTFS -NewFileSystemLabel 'EZMV_TARGET' -Confirm:$false | Out-Null
    $null = New-Partition -DiskNumber $diskNo -Size 200MB -GptType $recoveryType
    $dL = Get-FreeLetter
    $dpart = New-Partition -DiskNumber $diskNo -UseMaximumSize -DriveLetter $dL
    Format-Volume -Partition $dpart -FileSystem NTFS -NewFileSystemLabel 'EZMV_DATA' -Confirm:$false | Out-Null
    Start-Sleep -Seconds 2
    Write-Host ('  disk ' + $diskNo + ': target ' + $tL + ':  data ' + $dL + ':')
    Show-Layout $diskNo

    Write-Host 'Writing test files' -ForegroundColor Cyan
    $dataRoot = $dL + ':\'
    $rng = New-Object System.Random 7
    New-Item -ItemType Directory -Path ($dataRoot + 'docs'), ($dataRoot + 'media\deep\deeper') | Out-Null
    Set-Content -Path ($dataRoot + 'docs\readme.txt') -Value 'ezmv test file' -Encoding ASCII
    foreach ($i in 1..12) {
        $b = New-Object byte[] (4MB)
        $rng.NextBytes($b)
        [System.IO.File]::WriteAllBytes(($dataRoot + 'media\file' + $i + '.bin'), $b)
    }
    [System.IO.File]::WriteAllBytes(($dataRoot + 'media\deep\deeper\empty.dat'), (New-Object byte[] 0))
    Set-Content -Path ($dataRoot + 'docs\hidden.txt') -Value 'hidden' -Encoding ASCII
    (Get-Item ($dataRoot + 'docs\hidden.txt')).Attributes = 'Hidden'
    Set-Content -Path ($dataRoot + 'docs\stream.txt') -Value 'main' -Encoding ASCII
    Set-Content -Path ($dataRoot + 'docs\stream.txt') -Stream 'note' -Value 'alternate stream'
    $longDir = '\\?\' + $dataRoot + ('L' * 120) + '\' + ('M' * 120)
    [System.IO.Directory]::CreateDirectory($longDir) | Out-Null
    [System.IO.File]::WriteAllText($longDir + '\deep.txt', 'deep file')
    New-Item -ItemType Directory -Path ($tL + ':\linktarget') | Out-Null
    & cmd.exe /c mklink /J ($dataRoot + 'docs\link') ($tL + ':\linktarget') | Out-Null

    $manifest = @{}
    $tree = Get-Tree $dataRoot
    foreach ($rel in $tree.Files) { $manifest[$rel] = Get-Sha256 ($tree.Base + '\' + $rel) }
    Write-Host ('  ' + $manifest.Count + ' files recorded')

    $targetBefore = [int64](Get-Partition -DriveLetter $tL).Size
    $dataBefore = [int64](Get-Partition -DriveLetter $dL).Size
    $tEnd = [int64](Get-Partition -DriveLetter $tL).Offset + $targetBefore
    $gap = [int64](Get-Partition -DriveLetter $dL).Offset - $tEnd

    Write-Host ''
    Write-Host 'Run 1: interrupted after step 5' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ezmv -Target $tL -GiveGB 1 -Yes -VerifyHash -StatePath $statePath -StopAfterPhase 5
    $code1 = $LASTEXITCODE
    $mid = Read-State $statePath
    Check 'interrupted run exits with an error code' ($code1 -eq 1)
    Check 'resume file says step 5' ($mid -and [int]$mid.Phase -eq 5)
    Update-HostStorageCache
    Check 'data drive is gone at this point' (-not (Get-Partition -DriveLetter $dL -ErrorAction SilentlyContinue))
    Check 'temporary drive holds the files' ($mid -and (Test-Path ($mid.TempLetter + ':\docs\readme.txt')))
    Check 'recovery partition was removed' (@(Get-Partition -DiskNumber $diskNo | Where-Object { "$($_.GptType)" -eq $recoveryType }).Count -eq 0)

    Write-Host ''
    Write-Host 'Run 2: resume' -ForegroundColor Cyan
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ezmv -Yes -StatePath $statePath
    $code2 = $LASTEXITCODE
    Update-HostStorageCache

    Write-Host ''
    Write-Host 'Checking the result' -ForegroundColor Cyan
    Check 'resumed run exits cleanly' ($code2 -eq 0)
    Check 'resume file was removed' (-not (Test-Path $statePath))
    $targetAfter = [int64](Get-Partition -DriveLetter $tL).Size
    Check ('target grew by 1 GB (' + (ToGB $targetBefore) + ' -> ' + (ToGB $targetAfter) + ' GB)') ([math]::Abs($targetAfter - $targetBefore - 1GB) -le 1MB)
    $dNew = Get-Partition -DriveLetter $dL -ErrorAction SilentlyContinue
    Check 'data drive is back under the same letter' ([bool]$dNew)
    if ($dNew) {
        $expected = $dataBefore + $gap - 1GB
        Check ('data drive size is about ' + (ToGB $expected) + ' GB (is ' + (ToGB $dNew.Size) + ')') ([math]::Abs([int64]$dNew.Size - $expected) -le 16MB)
        Check 'data drive starts right after the target' (([int64]$dNew.Offset - ([int64](Get-Partition -DriveLetter $tL).Offset + $targetAfter)) -le 1MB)
        Check 'label kept' ((Get-Volume -DriveLetter $dL).FileSystemLabel -eq 'EZMV_DATA')
    }
    Check 'temporary drive is gone' ($mid -and -not (Get-Partition -DriveLetter $mid.TempLetter -ErrorAction SilentlyContinue))
    Check 'no unallocated space left' ([int64](Get-Disk -Number $diskNo).LargestFreeExtent -le 16MB)

    $bad = 0
    foreach ($rel in $manifest.Keys) {
        if ((Get-Sha256 ('\\?\' + $dL + ':\' + $rel)) -ne $manifest[$rel]) { $bad++ }
    }
    Check ('all ' + $manifest.Count + ' files have identical content') ($bad -eq 0)
    Check 'no extra files appeared' ((Get-Tree ($dL + ':\')).Files.Count -eq $manifest.Count)
    Check 'hidden attribute kept' (((Get-Item ($dL + ':\docs\hidden.txt') -Force).Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0)
    Check 'alternate data stream kept' ("$(Get-Content -Path ($dL + ':\docs\stream.txt') -Stream 'note' -ErrorAction SilentlyContinue)" -eq 'alternate stream')
    Check 'junction was skipped, not followed' (-not (Test-Path ($dL + ':\docs\link')))
    Show-Layout $diskNo
}
catch {
    Write-Host ('TEST ERROR: ' + $_.Exception.Message) -ForegroundColor Red
    $script:Failed++
}
finally {
    if ($mounted -and -not $KeepDisk) {
        try { Dismount-DiskImage -ImagePath $vhd | Out-Null } catch { }
        Start-Sleep -Seconds 1
        try { Remove-Item $WorkDir -Recurse -Force } catch { Write-Host ('cleanup: ' + $_.Exception.Message) -ForegroundColor Yellow }
    } elseif ($KeepDisk) {
        Write-Host ('Virtual disk kept: ' + $vhd)
    }
}

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host 'Virtual disk test passed.' -ForegroundColor Green
    exit 0
}
Write-Host ($script:Failed.ToString() + ' check(s) failed.') -ForegroundColor Red
exit 1
