<#
.SYNOPSIS
    Removes the LogBackup scheduled tasks (rollback for Register-BackupTask.ps1).
    The repository, password file, state and logs are left untouched.
#>
[CmdletBinding(SupportsShouldProcess)]
param([string[]]$TaskName = @('LogBackup - Daily', 'LogBackup - Watchdog'))

$ErrorActionPreference = 'Stop'
foreach ($name in $TaskName) {
    if (-not (Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)) {
        Write-Output "'$name' is not registered; nothing to do."
        continue
    }
    if ($PSCmdlet.ShouldProcess($name, 'Unregister scheduled task')) {
        Unregister-ScheduledTask -TaskName $name -Confirm:$false
        Write-Output "Removed '$name'."
    }
}
