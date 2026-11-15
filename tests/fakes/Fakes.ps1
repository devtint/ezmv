<#
    Test doubles for ezmv, dot-sourced into the PowerShell session that runs
    ezmv. They replace BitLocker, Windows Recovery (reagentc.exe) and Read-Host
    with fakes whose state is kept in a JSON file, so it survives a killed
    process just like the real settings would.

    $env:EZMV_FAKE_STATE   path of the JSON file
    $env:EZMV_FAKE_ANSWERS comma-separated answers for Read-Host, in order
#>
$global:FakeStatePath = $env:EZMV_FAKE_STATE

function global:Read-FakeState { Get-Content -LiteralPath $global:FakeStatePath -Raw | ConvertFrom-Json }
function global:Write-FakeState($State) { $State | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $global:FakeStatePath -Encoding UTF8 }
function global:Add-FakeCall([string]$Text) {
    $s = Read-FakeState
    $s.Calls = @($s.Calls) + $Text
    Write-FakeState $s
}

# ---- BitLocker: only the drive named in BitLockerLetter is encrypted --------
function global:Get-BitLockerVolume {
    param([string]$MountPoint)
    $s = Read-FakeState
    if ($MountPoint.TrimEnd(':').ToUpper() -eq "$($s.BitLockerLetter)".ToUpper()) {
        $status = 'Off'
        if ($s.BitLockerOn) { $status = 'On' }
        return [pscustomobject]@{ MountPoint = $MountPoint; VolumeStatus = 'FullyEncrypted'; ProtectionStatus = $status; LockStatus = 'Unlocked' }
    }
    return [pscustomobject]@{ MountPoint = $MountPoint; VolumeStatus = 'FullyDecrypted'; ProtectionStatus = 'Off'; LockStatus = 'Unlocked' }
}
function global:Suspend-BitLocker {
    param([string]$MountPoint, [int]$RebootCount)
    $s = Read-FakeState; $s.BitLockerOn = $false; Write-FakeState $s
    Add-FakeCall ('Suspend-BitLocker ' + $MountPoint)
}
function global:Resume-BitLocker {
    param([string]$MountPoint)
    $s = Read-FakeState; $s.BitLockerOn = $true; Write-FakeState $s
    Add-FakeCall ('Resume-BitLocker ' + $MountPoint)
}

# ---- Windows Recovery: reagentc.exe /info | /disable | /enable --------------
function global:Invoke-FakeReAgentC {
    $s = Read-FakeState
    switch ("$($args[0])".ToLower()) {
        '/info' {
            if ($s.WinReEnabled) {
                'Windows RE status:         Enabled'
                ('Windows RE location:       \\?\GLOBALROOT\device\harddisk' + $s.WinReDisk + '\partition' + $s.WinRePartition + '\Recovery\WindowsRE')
            } else {
                'Windows RE status:         Disabled'
                'Windows RE location:'
            }
        }
        '/disable' { $s.WinReEnabled = $false; Write-FakeState $s; Add-FakeCall 'reagentc /disable'; 'REAGENTC.EXE: Operation Successful.' }
        '/enable'  { $s.WinReEnabled = $true;  Write-FakeState $s; Add-FakeCall 'reagentc /enable';  'REAGENTC.EXE: Operation Successful.' }
        default    { throw ('fake reagentc: unexpected arguments ' + ($args -join ' ')) }
    }
}
Set-Alias -Name 'reagentc.exe' -Value Invoke-FakeReAgentC -Scope Global

# ---- Read-Host: answers come from EZMV_FAKE_ANSWERS ------------------------
$global:FakeAnswers = New-Object System.Collections.Queue
foreach ($a in ("$env:EZMV_FAKE_ANSWERS" -split ',')) { if ($a) { $global:FakeAnswers.Enqueue($a) } }
function global:Read-Host {
    param([Parameter(Position = 0)] $Prompt)
    if ($global:FakeAnswers.Count -eq 0) { throw ('Unexpected question (no fake answer left): ' + $Prompt) }
    $a = $global:FakeAnswers.Dequeue()
    Write-Host ($Prompt + ': ' + $a + '  [fake answer]')
    return $a
}
