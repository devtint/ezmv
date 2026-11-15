<#
.SYNOPSIS
    Tests the file-handling parts of ezmv (copy, verify, hash, link detection,
    resume file) in a temporary folder. Needs no admin rights and never touches
    a partition.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\Test-Functions.ps1
#>
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'ezmv.ps1')

# plain copy flags so the test runs without backup privileges
$script:RoboCopyFlags = @('/COPY:DAT')
$script:RoboVerifyFlags = @()

$script:Failed = 0
function Check([string]$Name, [bool]$Condition) {
    if ($Condition) {
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    } else {
        Write-Host ('  FAIL  ' + $Name) -ForegroundColor Red
        $script:Failed++
    }
}

$root = Join-Path $env:TEMP ('ezmv test ' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$src = Join-Path $root 'src dir'
$dst = Join-Path $root 'dst dir'
$outside = Join-Path $root 'outside'
$link = Join-Path $src 'sub\link'

try {
    New-Item -ItemType Directory -Path $src, $dst, $outside, (Join-Path $src 'sub'), (Join-Path $src '$RECYCLE.BIN'), (Join-Path $src 'System Volume Information') | Out-Null

    Set-Content -Path (Join-Path $src 'a.txt') -Value 'hello world' -Encoding ASCII
    $bytes = New-Object byte[] (1MB)
    (New-Object System.Random 42).NextBytes($bytes)
    [System.IO.File]::WriteAllBytes((Join-Path $src 'sub\b.bin'), $bytes)
    [System.IO.File]::WriteAllBytes((Join-Path $src 'sub\empty.dat'), (New-Object byte[] 0))
    Set-Content -Path (Join-Path $src 'hidden.txt') -Value 'secret' -Encoding ASCII
    (Get-Item (Join-Path $src 'hidden.txt')).Attributes = 'Hidden'
    Set-Content -Path (Join-Path $src '$RECYCLE.BIN\junk.txt') -Value 'junk' -Encoding ASCII
    Set-Content -Path (Join-Path $src 'System Volume Information\svi.txt') -Value 'svi' -Encoding ASCII
    Set-Content -Path (Join-Path $outside 'outside.txt') -Value 'must not be copied' -Encoding ASCII

    $longDir = '\\?\' + $src + '\' + ('L' * 120) + '\' + ('M' * 120)
    [System.IO.Directory]::CreateDirectory($longDir) | Out-Null
    [System.IO.File]::WriteAllText($longDir + '\deep.txt', 'deep file')

    & cmd.exe /c mklink /J $link $outside | Out-Null

    Write-Host ''
    Write-Host 'Tree walking' -ForegroundColor Cyan
    $tree = Get-Tree $src
    Check 'finds the junction and does not follow it' ($tree.Links.Count -eq 1 -and $tree.Links[0] -eq 'sub\link')
    Check 'lists 5 files (root excludes skipped, long path included)' ($tree.Files.Count -eq 5)
    Check 'long path file is listed' (@($tree.Files | Where-Object { $_ -like '*deep.txt' }).Count -eq 1)
    Check 'LinksOnly lists no files' ((Get-Tree $src -LinksOnly).Files.Count -eq 0)

    Write-Host ''
    Write-Host 'Copy and verify' -ForegroundColor Cyan
    $code = Copy-Tree $src $dst (Join-Path $root 'copy.log') 0 ''
    Check ('robocopy exit code below 8 (was ' + $code + ')') ($code -lt 8)
    Check 'verify passes after copy' ((Test-TreeCopy $src $dst).Ok)
    Check 'recycle bin was not copied' (-not (Test-Path (Join-Path $dst '$RECYCLE.BIN')))
    Check 'System Volume Information was not copied' (-not (Test-Path (Join-Path $dst 'System Volume Information')))
    Check 'junction target was not copied' (-not (Test-Path (Join-Path $dst 'sub\link\outside.txt')))
    Check 'hidden attribute kept' (((Get-Item (Join-Path $dst 'hidden.txt') -Force).Attributes -band [System.IO.FileAttributes]::Hidden) -ne 0)
    Check 'long path file copied' ([System.IO.File]::Exists('\\?\' + $dst + '\' + ('L' * 120) + '\' + ('M' * 120) + '\deep.txt'))
    $h = Compare-TreeHash $src $dst
    Check ('hash compare passes for ' + $h.Count + ' files') ($h.Ok -and $h.Count -eq 5 -and $h.Unreadable -eq 0)

    Write-Host ''
    Write-Host 'Detecting damage' -ForegroundColor Cyan
    $victim = Join-Path $dst 'a.txt'
    $stampTime = (Get-Item $victim).LastWriteTimeUtc
    Set-Content -Path $victim -Value 'HELLO WORLD' -Encoding ASCII
    (Get-Item $victim).LastWriteTimeUtc = $stampTime
    Check 'same size and date still passes the quick verify' ((Test-TreeCopy $src $dst).Ok)
    $h = Compare-TreeHash $src $dst
    Check 'hash compare catches the changed content' ((-not $h.Ok) -and $h.Mismatch.Count -eq 1 -and $h.Mismatch[0] -eq 'a.txt')
    Remove-Item (Join-Path $dst 'sub\b.bin') -Force
    $v = Test-TreeCopy $src $dst
    Check 'quick verify catches a missing file' ((-not $v.Ok) -and $v.Lines.Count -ge 1)
    Set-Content -Path (Join-Path $dst 'extra.txt') -Value 'extra' -Encoding ASCII
    $code = Copy-Tree $src $dst (Join-Path $root 'copy2.log') 0 ''
    Check 'second copy repairs the destination' (($code -lt 8) -and (Test-TreeCopy $src $dst).Ok)

    Write-Host ''
    Write-Host 'Helpers' -ForegroundColor Cyan
    Check 'Get-RoboPath keeps a drive root' ((Get-RoboPath 'D:\') -eq 'D:\' -and (Get-RoboPath 'D:') -eq 'D:\')
    Check 'Get-RoboPath trims a folder' ((Get-RoboPath 'C:\some dir\') -eq 'C:\some dir')
    Check 'FloorMB / CeilMB' ((FloorMB (1MB + 5)) -eq 1MB -and (CeilMB (1MB + 5)) -eq 2MB)

    $statePath = Join-Path $root 'state\state.json'
    $state = [pscustomobject]@{
        Phase = 4; DiskNumber = 7; TargetLetter = 'C'; DonorLetter = 'D'; TempLetter = 'T'
        DonorOffset = [int64]296667316224; GiveBytes = [int64]10737418240
        BetweenOffsets = @([int64]295580991488); VerifyHash = $true
    }
    Save-State $state $statePath
    $back = Read-State $statePath
    Check 'resume file round trip keeps large numbers' ([int64]$back.DonorOffset -eq 296667316224 -and [int]$back.Phase -eq 4)
    Check 'resume file keeps a one-element list as a list' (@($back.BetweenOffsets).Count -eq 1 -and [int64]@($back.BetweenOffsets)[0] -eq 295580991488)
    Check 'state text warns when files are only on the temp drive' ((Get-StateText $back) -like '*ONLY ON T:*')
    Check 'missing resume file reads as nothing' ($null -eq (Read-State (Join-Path $root 'nope.json')))
}
finally {
    try { if (Test-Path $link) { [System.IO.Directory]::Delete($link) } } catch { }
    try { [System.IO.Directory]::Delete(('\\?\' + $root), $true) } catch { Write-Host ('cleanup: ' + $_.Exception.Message) -ForegroundColor Yellow }
}

Write-Host ''
if ($script:Failed -eq 0) {
    Write-Host 'All function tests passed.' -ForegroundColor Green
    exit 0
}
Write-Host ($script:Failed.ToString() + ' test(s) failed.') -ForegroundColor Red
exit 1
