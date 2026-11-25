<#
.SYNOPSIS
    Registers the two scheduled tasks: the daily backup and the watchdog.

.DESCRIPTION
    "LogBackup - Daily"     runs Invoke-LogBackup.ps1 (Backup mode) every day at -Time.
    "LogBackup - Watchdog"  runs Invoke-LogBackup.ps1 -Mode StaleCheck every 6 hours, so a
                            backup task that silently stopped running still raises an ALERT.

    Before registering, a pre-flight check loads the config, reads the repository password
    (DPAPI file or RESTIC_PASSWORD) and runs `restic cat config` against the repository.
    Run this as the account that will run the tasks (DPAPI secrets are per user).
    Use -WhatIf to preview. Roll back with Unregister-BackupTask.ps1.

.EXAMPLE
    .\scripts\Register-BackupTask.ps1 -Time 02:30 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ProjectDir = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string]$ConfigPath,
    [ValidatePattern('^\d{2}:\d{2}$')][string]$Time = '02:00',
    [ValidateRange(1, 24)][int]$WatchdogEveryHours = 6,
    [switch]$SkipPreflight
)

$ErrorActionPreference = 'Stop'
if (-not $ConfigPath) { $ConfigPath = Join-Path $ProjectDir 'config\backup.config.json' }
Import-Module (Join-Path $ProjectDir 'src\LogBackup\LogBackup.psd1') -Force
$entry = Join-Path $ProjectDir 'src\Invoke-LogBackup.ps1'

if (-not $SkipPreflight) {
    $config = Get-BackupConfig -Path $ConfigPath
    $password = Get-RepositoryPassword -Config $config
    $probe = Invoke-Restic -Arguments @('cat', 'config') -Config $config -Password $password
    if ($probe.ExitCode -ne 0) { throw "Pre-flight failed: $(Get-ResticFailureHint $probe.ExitCode $probe.StdErr)" }
    Write-Output "Pre-flight OK: config valid, password works, repository reachable ($($config.repository))."
}

$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$common = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$entry`" -ConfigPath `"$ConfigPath`""
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Hours 4) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

$tasks = @(
    @{ Name = 'LogBackup - Daily'; Args = $common; Trigger = (New-ScheduledTaskTrigger -Daily -At $Time); Desc = "Encrypted log backup (restic). Exit 0 OK, 1 WARNING, 2 ALERT, 3 could not run." },
    @{ Name = 'LogBackup - Watchdog'; Args = "$common -Mode StaleCheck"
        Trigger = (New-ScheduledTaskTrigger -Once -At (Get-Date).Date.AddHours(1) -RepetitionInterval (New-TimeSpan -Hours $WatchdogEveryHours) -RepetitionDuration (New-TimeSpan -Days 3650))
        Desc = 'Alerts when the last good log backup is too old.' }
)
foreach ($t in $tasks) {
    if ($PSCmdlet.ShouldProcess($t.Name, "Register scheduled task: powershell.exe $($t.Args)")) {
        $action = New-ScheduledTaskAction -Execute $ps -Argument $t.Args -WorkingDirectory $ProjectDir
        Register-ScheduledTask -TaskName $t.Name -Action $action -Trigger $t.Trigger -Settings $settings -Description $t.Desc -Force | Out-Null
        Write-Output "Registered '$($t.Name)'; next run $((Get-ScheduledTaskInfo -TaskName $t.Name).NextRunTime)"
    }
}
Write-Output "Test now: Start-ScheduledTask -TaskName 'LogBackup - Daily'   Roll back: .\scripts\Unregister-BackupTask.ps1"
