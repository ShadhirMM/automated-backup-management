<#
.SYNOPSIS
    Stores the alert webhook URL with Windows DPAPI (notify.webhookFile in the config)
    and optionally sends a test message.

.DESCRIPTION
    Anyone with the webhook URL can post to the channel, so it is kept out of the config
    and the repository. Alternatively set the environment variable named in
    notify.webhookEnv (default BACKUP_WEBHOOK_URL) for the task account.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\backup.config.json'),
    [switch]$SendTest
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\LogBackup\LogBackup.psd1') -Force
$config = Get-BackupConfig -Path $ConfigPath
if (-not $config.notify.webhookFile) { throw 'Set notify.webhookFile in the config first.' }

$url = Read-Host -AsSecureString -Prompt 'Webhook URL (Slack / Teams / any JSON endpoint)'
$plain = ConvertFrom-SecureStringToPlain -SecureString $url
if ($plain -notmatch '^https://') { throw 'The webhook URL must start with https://' }
Save-ProtectedSecret -Secret $url -Path $config.notify.webhookFile
Write-Output "Saved (DPAPI): $($config.notify.webhookFile)"

if ($SendTest) {
    $report = [pscustomobject]@{
        status = 'OK'; jobName = $config.jobName; host = $config.hostTag; mode = 'Test'; runId = 'webhook-test'
        steps = @((New-StepResult 'notification' 'OK' 'Test message from Set-BackupWebhook.ps1'))
    }
    Write-Output "Test message: $(Send-BackupNotification -Uri $plain -Report $report)"
}
