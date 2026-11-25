@{
    RootModule        = 'LogBackup.psm1'
    ModuleVersion     = '1.0.0'
    GUID              = '6f0c2a7e-4c1b-4f7e-9b8e-2d6a1c5e9f31'
    Author            = 'Mushaff Shadhir'
    Copyright         = '(c) 2026 Mushaff Shadhir. MIT License.'
    Description       = 'Copies designated log folders into an encrypted restic repository with integrity verification, retention, recovery testing and OK/WARNING/ALERT notifications.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Get-BackupConfig',
        'Get-Prop',
        'Resolve-BackupPath',
        'Get-RepositoryPassword',
        'Get-WebhookUrl',
        'Save-ProtectedSecret',
        'Get-ProtectedSecret',
        'ConvertFrom-SecureStringToPlain',
        'ConvertTo-ReadOnlySecureString',
        'Write-BackupLog',
        'ConvertTo-UtcDate',
        'Enter-BackupLock',
        'Exit-BackupLock',
        'Get-BackupState',
        'Save-BackupState',
        'Test-IsDue',
        'Get-HoursSince',
        'ConvertTo-ProcessArgument',
        'ConvertTo-ResticPath',
        'Invoke-Restic',
        'Get-ResticFailureHint',
        'ConvertFrom-ResticJson',
        'New-StepResult',
        'Get-OverallStatus',
        'Copy-SourceToStaging',
        'New-BackupManifest',
        'Invoke-ResticBackup',
        'Compare-ManifestToSnapshot',
        'Test-BackupSnapshot',
        'Get-RetentionArgumentList',
        'Invoke-Retention',
        'Invoke-RestoreTest',
        'Format-BackupReportText',
        'Send-BackupNotification',
        'Write-BackupEventLog',
        'Get-ExitCodeForStatus',
        'Invoke-LogBackupRun',
        'Get-StalenessStep'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{ PSData = @{ Tags = @('backup', 'restic', 'logs', 'encryption'); LicenseUri = 'https://opensource.org/licenses/MIT' } }
}
