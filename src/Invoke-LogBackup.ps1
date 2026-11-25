<#
.SYNOPSIS
    Runs the log backup job (entry point for Task Scheduler).

.DESCRIPTION
    Backup      (default) copy sources to staging -> SHA-256 manifest -> restic backup ->
                verify (manifest vs snapshot + restic check) -> retention -> recovery test when due
                -> staleness check -> report + notification.
    RestoreTest restore the latest snapshot to a temp folder and verify every file's SHA-256.
    Verify      full repository check (all data read back).
    StaleCheck  ALERT if the last good backup is older than thresholds.maxHoursSinceSuccess.

    Exit codes: 0 OK, 1 WARNING, 2 ALERT, 3 could not run (config, lock, password, restic missing).

.EXAMPLE
    .\src\Invoke-LogBackup.ps1
.EXAMPLE
    .\src\Invoke-LogBackup.ps1 -Mode RestoreTest
.EXAMPLE
    .\src\Invoke-LogBackup.ps1 -ConfigPath .\config\backup.config.json -ForceRestoreTest
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\backup.config.json'),
    [ValidateSet('Backup', 'RestoreTest', 'Verify', 'StaleCheck')]
    [string]$Mode = 'Backup',
    [switch]$ForceRestoreTest,
    [switch]$NoNotify
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LogBackup\LogBackup.psd1') -Force

$report = Invoke-LogBackupRun -ConfigPath $ConfigPath -Mode $Mode -ForceRestoreTest:$ForceRestoreTest -NoNotify:$NoNotify
Write-Output (Format-BackupReportText $report)
Write-Output "Exit code $($report.exitCode); report: $($report.reportPath); notification: $($report.notification)"
exit $report.exitCode
