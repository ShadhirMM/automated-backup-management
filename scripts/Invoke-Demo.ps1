<#
.SYNOPSIS
    End-to-end demonstration with fake log folders and a throw-away repository.
    Shows: a good backup with recovery test, an incremental run, a missing source,
    and detection of a damaged repository. Needs restic (scripts\Install-Restic.ps1).
    Nothing outside a temporary folder is touched.
#>
[CmdletBinding()]
param([string]$ResticPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\bin\restic.exe'))

$ErrorActionPreference = 'Stop'
$project = Split-Path $PSScriptRoot -Parent
. (Join-Path $project 'tests\TestHelpers.ps1')
Import-Module (Join-Path $project 'src\LogBackup\LogBackup.psd1') -Force
if ($env:RESTIC_EXE) { $ResticPath = $env:RESTIC_EXE }

$root = New-TestRoot
$oldPw = $env:RESTIC_PASSWORD
$env:RESTIC_PASSWORD = 'demo-only-passphrase-not-secret'
try {
    New-DemoLogFolder -Path (Join-Path $root 'src\app') -Files 3 -Prefix 'app'
    New-DemoLogFolder -Path (Join-Path $root 'src\sys') -Files 2 -Prefix 'sys'
    $cfgPath = New-TestConfig -Root $root -ResticPath $ResticPath -Retention @{ keepDaily = 14; keepWeekly = 8; keepMonthly = 12 } -ReadDataSubsetPercent 10 -FullReadEveryDays 30
    $cfg = Get-BackupConfig -Path $cfgPath
    $null = Invoke-Restic -Arguments @('init') -Config $cfg -Password (Get-RepositoryPassword -Config $cfg)

    function Show($title, $report) {
        Write-Output ''
        Write-Output "### $title"
        Write-Output (Format-BackupReportText $report)
        Write-Output "exit code: $($report.exitCode)"
    }

    $codes = @()
    $r = Invoke-LogBackupRun -ConfigPath $cfgPath -ForceRestoreTest -NoNotify 6>$null; $codes += $r.exitCode
    Show '1. First backup (recovery test forced)' $r
    Add-Content (Join-Path $root 'src\app\app-2026-11-03.log') '2026-11-03T09:00:00Z INFO app request id=999 status=200'
    $r = Invoke-LogBackupRun -ConfigPath $cfgPath -NoNotify 6>$null; $codes += $r.exitCode
    Show '2. Next day: one log grew' $r
    Rename-Item (Join-Path $root 'src\sys') 'sys-moved'
    $r = Invoke-LogBackupRun -ConfigPath $cfgPath -NoNotify 6>$null; $codes += $r.exitCode
    Show '3. A log folder disappeared' $r
    $pack = Get-ChildItem (Join-Path $cfg.repository 'data') -Recurse -File | Sort-Object Length -Descending | Select-Object -First 1
    $pack.IsReadOnly = $false
    $bytes = [IO.File]::ReadAllBytes($pack.FullName)
    for ($i = 100; $i -lt [Math]::Min(400, $bytes.Length); $i++) { $bytes[$i] = $bytes[$i] -bxor 0xFF }
    [IO.File]::WriteAllBytes($pack.FullName, $bytes)
    $r = Invoke-LogBackupRun -ConfigPath $cfgPath -Mode Verify -NoNotify 6>$null; $codes += $r.exitCode
    Show '4. Repository file damaged on disk, full verification' $r
    Write-Output ''
    $expected = '0,0,2,2'
    if (($codes -join ',') -eq $expected) { Write-Output "Demo outcome as expected (exit codes $expected)."; exit 0 }
    Write-Output "Unexpected exit codes: $($codes -join ',') (expected $expected)"
    exit 1
}
finally {
    $env:RESTIC_PASSWORD = $oldPw
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
