<#
.SYNOPSIS
    One-time set-up: stores the repository password with Windows DPAPI and creates the
    encrypted restic repository.

.DESCRIPTION
    Run this AS THE ACCOUNT THAT WILL RUN THE SCHEDULED TASK: DPAPI-protected files can
    only be read by the same user on the same machine.

    The password is the only key to the backups. restic cannot recover data without it.
    Store a copy in the company password manager (key escrow) BEFORE the first backup.

    If the repository already exists, only the password file is (re)written and checked
    against it; an existing repository is never re-initialised.

.EXAMPLE
    .\scripts\Initialize-BackupRepository.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\backup.config.json')
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\LogBackup\LogBackup.psd1') -Force
$config = Get-BackupConfig -Path $ConfigPath

$first = Read-Host -AsSecureString -Prompt 'Repository password (min 16 characters)'
$second = Read-Host -AsSecureString -Prompt 'Repeat password'
$p1 = ConvertFrom-SecureStringToPlain -SecureString $first
$p2 = ConvertFrom-SecureStringToPlain -SecureString $second
if ($p1 -ne $p2) { throw 'Passwords do not match.' }
if ($p1.Length -lt 16) { throw 'Use at least 16 characters (a passphrase of several words is fine).' }

$probe = Invoke-Restic -Arguments @('cat', 'config') -Config $config -Password $first
if ($probe.ExitCode -eq 0) {
    Write-Output "Repository already exists at $($config.repository) and the password is correct."
}
elseif ($probe.ExitCode -eq 12 -or $probe.StdErr -match 'wrong password|no key found') {
    throw 'A repository exists at this location but the password is wrong. Nothing was changed.'
}
elseif ($PSCmdlet.ShouldProcess($config.repository, 'Create encrypted restic repository')) {
    $init = Invoke-Restic -Arguments @('init') -Config $config -Password $first
    if ($init.ExitCode -ne 0) { throw "restic init failed (exit $($init.ExitCode)): $($init.StdErr)" }
    Write-Output "Created encrypted repository at $($config.repository)."
}

if ($PSCmdlet.ShouldProcess($config.passwordFile, 'Save DPAPI-protected password')) {
    Save-ProtectedSecret -Secret $first -Path $config.passwordFile
    Write-Output "Password saved (DPAPI, this user on this machine only): $($config.passwordFile)"
}
Write-Warning 'KEY ESCROW: store the repository password in the company password manager now. Without it the backups cannot be restored.'

