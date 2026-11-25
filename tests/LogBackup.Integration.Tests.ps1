#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Integration tests against the REAL restic binary (tools\bin\restic.exe or $env:RESTIC_EXE).
# Every test uses its own temporary source folders and repository.
# Skipped when restic is not installed (run scripts\Install-Restic.ps1 first).

BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:HaveRestic = [bool](Get-ResticExe)
}

Describe 'LogBackup with real restic' -Tag 'Integration' -Skip:(-not $script:HaveRestic) {
    BeforeAll {
        . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
        Import-Module $script:ModulePath -Force
        $script:Restic = Get-ResticExe
        $script:Password = 'integration-test-passphrase-01'
        $script:SecurePassword = ConvertTo-TestSecureString $script:Password

        function New-Env {
            param([hashtable]$Retention = @{ keepDaily = 30; keepWeekly = 0; keepMonthly = 0 }, [object[]]$Sources, [string]$Repository)
            $root = New-TestRoot
            New-DemoLogFolder -Path (Join-Path $root 'src\app') -Files 3 -Prefix 'app'
            New-DemoLogFolder -Path (Join-Path $root 'src\sys') -Files 2 -Prefix 'sys'
            $cfgPath = New-TestConfig -Root $root -ResticPath $script:Restic -Retention $Retention -Sources $Sources -Repository $Repository
            $cfg = Get-BackupConfig -Path $cfgPath
            [pscustomobject]@{ Root = $root; ConfigPath = $cfgPath; Config = $cfg }
        }
        function Initialize-Repo($cfg) {
            $r = Invoke-Restic -Arguments @('init') -Config $cfg -Password $script:SecurePassword
            if ($r.ExitCode -ne 0) { throw "init failed: $($r.StdErr)" }
        }
        function Get-TestSnapshot($cfg) {
            $r = Invoke-Restic -Arguments @('snapshots', '--json') -Config $cfg -Password $script:SecurePassword
            @(ConvertFrom-ResticJson $r.StdOut | ForEach-Object { $_ })
        }
        function Step($report, $name) { $report.steps | Where-Object Name -eq $name }

        $env:RESTIC_PASSWORD = $script:Password
        Write-Information -MessageData ((& $script:Restic version) -join " ") -InformationAction Continue
    }
    AfterAll {
        $env:RESTIC_PASSWORD = $null
    }

    Context 'Happy path' {
        BeforeAll {
            $script:E = New-Env
            Initialize-Repo $script:E.Config
            $script:R1 = Invoke-LogBackupRun -ConfigPath $script:E.ConfigPath -ForceRestoreTest -NoNotify 6>$null
        }

        It 'first run is OK with every step passing' {
            Write-Information -MessageData (($script:R1.steps | ForEach-Object { "$($_.Name)=$($_.Status): $($_.Message)" }) -join "`n") -InformationAction Continue
            $script:R1.status | Should -Be 'OK'
            $script:R1.exitCode | Should -Be 0
            (Step $script:R1 'copy:app-logs').Status | Should -Be 'OK'
            (Step $script:R1 'copy:sys-logs').Status | Should -Be 'OK'
            (Step $script:R1 'backup').Status | Should -Be 'OK'
            (Step $script:R1 'verify').Status | Should -Be 'OK'
            (Step $script:R1 'retention').Status | Should -Be 'OK'
            (Step $script:R1 'restore-test').Status | Should -Be 'OK'
            (Step $script:R1 'staleness').Status | Should -Be 'OK'
        }

        It 'stores the snapshot encrypted (no log text readable in the repository files)' {
            $needle = [Text.Encoding]::UTF8.GetBytes('request id=')
            $hit = $false
            foreach ($f in Get-ChildItem -LiteralPath $script:E.Config.repository -Recurse -File) {
                $bytes = [IO.File]::ReadAllBytes($f.FullName)
                $text = [Text.Encoding]::ASCII.GetString($bytes)
                if ($text.Contains('request id=')) { $hit = $true; break }
            }
            $needle.Length | Should -BeGreaterThan 0
            $hit | Should -BeFalse
        }

        It 'tags the snapshot with job and run id, and verified every file' {
            $snaps = @(Get-TestSnapshot $script:E.Config)
            $snaps.Count | Should -Be 1
            $snaps[0].tags | Should -Contain 'logbackup'
            $snaps[0].tags | Should -Contain "run:$($script:R1.runId)"
            $snaps[0].hostname | Should -Be 'TESTHOST'
            # app: 3 logs + archive\old.log (scratch.tmp excluded) = 4; sys: 2 logs + old.log + scratch.tmp = 4
            (Step $script:R1 'verify').Message | Should -Match '^8 file\(s\) match the manifest'
            (Step $script:R1 'restore-test').Data.checked | Should -Be 8
        }

        It 'records state and a JSON report, and cleans up the unencrypted staging copy' {
            $state = Get-BackupState -Path (Join-Path $script:E.Config.workDir 'state\state.json')
            $state.lastSuccessUtc | Should -Not -BeNullOrEmpty
            $state.lastRestoreTestUtc | Should -Not -BeNullOrEmpty
            $state.lastSnapshotId | Should -Be $script:R1.snapshotId
            Test-Path $script:R1.reportPath | Should -BeTrue
            Test-Path (Join-Path $script:E.Config.workDir 'staging') | Should -BeFalse
            Test-Path (Join-Path $script:E.Config.workDir 'backup.lock') | Should -BeFalse
        }

        It 'second run picks up new log lines and skips the restore test when not due' {
            Add-Content (Join-Path $script:E.Root 'src\app\app-2026-11-03.log') 'new line after first backup'
            $r2 = Invoke-LogBackupRun -ConfigPath $script:E.ConfigPath -NoNotify 6>$null
            $r2.status | Should -Be 'OK'
            (Step $r2 'restore-test').Status | Should -Be 'SKIPPED'
            @(Get-TestSnapshot $script:E.Config).Count | Should -Be 2
            (Step $r2 'backup').Data.summary.files_changed | Should -BeGreaterOrEqual 1
        }

        It 'RestoreTest mode restores the latest snapshot and checks every hash' {
            $r = Invoke-LogBackupRun -ConfigPath $script:E.ConfigPath -Mode RestoreTest -NoNotify 6>$null
            $r.status | Should -Be 'OK'
            (Step $r 'restore-test').Message | Should -Match '8 file\(s\) verified by SHA-256'
        }

        It 'Verify mode reads back all data' {
            $r = Invoke-LogBackupRun -ConfigPath $script:E.ConfigPath -Mode Verify -NoNotify 6>$null
            $r.status | Should -Be 'OK'
        }

        It 'Restore-LogBackup.ps1 restores one source and proves it intact' {
            $target = Join-Path $script:E.Root 'restore-out'
            $out = & (Join-Path $script:ProjectRoot 'scripts\Restore-LogBackup.ps1') -ConfigPath $script:E.ConfigPath -Target $target -Source 'sys-logs' 6>$null
            ($out -join "`n") | Should -Match 'all SHA-256 hashes match'
            $dir = Get-ChildItem $target -Directory | Select-Object -First 1
            Test-Path (Join-Path $dir.FullName 'sys-logs\sys-2026-11-01.log') | Should -BeTrue
            Test-Path (Join-Path $dir.FullName 'app-logs') | Should -BeFalse
            (Get-FileHash (Join-Path $dir.FullName 'sys-logs\sys-2026-11-02.log')).Hash | Should -Be (Get-FileHash (Join-Path $script:E.Root 'src\sys\sys-2026-11-02.log')).Hash
        }

        It 'StaleCheck is OK right after a good backup' {
            (Invoke-LogBackupRun -ConfigPath $script:E.ConfigPath -Mode StaleCheck -NoNotify 6>$null).status | Should -Be 'OK'
        }
    }

    Context 'Failure paths' {
        It 'missing required source: ALERT, the other source is still backed up, and retention does not delete the complete snapshot' {
            $e = New-Env -Retention @{ keepDaily = 1; keepWeekly = 0; keepMonthly = 0 }
            Initialize-Repo $e.Config
            $good = Invoke-LogBackupRun -ConfigPath $e.ConfigPath -NoNotify 6>$null
            $good.status | Should -Be 'OK'
            $goodSuccess = (Get-BackupState -Path (Join-Path $e.Config.workDir 'state\state.json')).lastSuccessUtc
            Remove-Item (Join-Path $e.Root 'src\sys') -Recurse -Force
            $r = Invoke-LogBackupRun -ConfigPath $e.ConfigPath -NoNotify 6>$null
            $r.status | Should -Be 'ALERT'
            $r.exitCode | Should -Be 2
            (Step $r 'copy:sys-logs').Status | Should -Be 'ALERT'
            (Step $r 'backup').Status | Should -Be 'OK'
            (Step $r 'verify').Status | Should -Be 'OK'
            $r.snapshotId | Should -Not -BeNullOrEmpty
            (Step $r 'retention').Status | Should -Be 'SKIPPED'
            @(Get-TestSnapshot $e.Config).Count | Should -Be 2   # keep-daily 1 would otherwise have removed the complete snapshot
            [string](Get-BackupState -Path (Join-Path $e.Config.workDir 'state\state.json')).lastSuccessUtc | Should -Be ([string]$goodSuccess)
        }

        It 'wrong password: ALERT with the password hint, nothing deleted' {
            $e = New-Env
            Initialize-Repo $e.Config
            $env:RESTIC_PASSWORD = 'not-the-right-password'
            try { $r = Invoke-LogBackupRun -ConfigPath $e.ConfigPath -NoNotify 6>$null }
            finally { $env:RESTIC_PASSWORD = $script:Password }
            $r.exitCode | Should -Be 2
            (Step $r 'backup').Status | Should -Be 'ALERT'
            (Step $r 'backup').Hint | Should -Match 'Wrong repository password'
        }

        It 'repository unreachable: ALERT with the repository hint (never auto-initialised)' {
            $e = New-Env -Repository 'C:\no-such-drive-folder\repo-missing'
            $r = Invoke-LogBackupRun -ConfigPath $e.ConfigPath -NoNotify 6>$null
            $r.exitCode | Should -Be 2
            (Step $r 'backup').Hint | Should -Match 'Repository not found'
            Test-Path 'C:\no-such-drive-folder\repo-missing' | Should -BeFalse
        }

        It 'tampered repository data is detected by verification' {
            $e = New-Env
            Initialize-Repo $e.Config
            (Invoke-LogBackupRun -ConfigPath $e.ConfigPath -NoNotify 6>$null).status | Should -Be 'OK'
            $pack = Get-ChildItem (Join-Path $e.Config.repository 'data') -Recurse -File | Sort-Object Length -Descending | Select-Object -First 1
            $pack.IsReadOnly = $false
            $bytes = [IO.File]::ReadAllBytes($pack.FullName)
            for ($i = 100; $i -lt [Math]::Min(400, $bytes.Length); $i++) { $bytes[$i] = $bytes[$i] -bxor 0xFF }
            [IO.File]::WriteAllBytes($pack.FullName, $bytes)
            $r = Invoke-LogBackupRun -ConfigPath $e.ConfigPath -Mode Verify -NoNotify 6>$null
            $r.status | Should -Be 'ALERT'
            (Step $r 'verify').Message | Should -Match 'check --read-data failed'
        }

        It 'recovery test catches files that changed between manifest and backup' {
            $e = New-Env
            Initialize-Repo $e.Config
            $staging = Join-Path $e.Config.workDir 'staging'
            foreach ($s in $e.Config.sources) { Copy-SourceToStaging -Source $s -StagingRoot $staging -Config $e.Config | Out-Null }
            $manifest = New-BackupManifest -StagingRoot $staging -RunId 'tamper-run'
            Add-Content (Join-Path $staging 'app-logs\app-2026-11-01.log') 'line written after the manifest'
            $b = Invoke-ResticBackup -StagingRoot $staging -Config $e.Config -Password $script:SecurePassword -RunId 'tamper-run'
            $b.Status | Should -Be 'OK'
            $v = Test-BackupSnapshot -SnapshotId $b.Data.snapshotId -Manifest $manifest -StagingRoot $staging -Config $e.Config -Password $script:SecurePassword
            $v.Status | Should -Be 'ALERT'
            $v.Message | Should -Match 'size differs: app-logs/app-2026-11-01.log'
            $rt = Invoke-RestoreTest -Config $e.Config -Password $script:SecurePassword -SnapshotId $b.Data.snapshotId
            $rt.Status | Should -Be 'ALERT'
            $rt.Message | Should -Match 'hash mismatch: app-logs/app-2026-11-01.log'
        }

        It 'does not apply retention when verification fails' {
            $e = New-Env -Retention @{ keepDaily = 1; keepWeekly = 0; keepMonthly = 0 }
            Initialize-Repo $e.Config
            (Invoke-LogBackupRun -ConfigPath $e.ConfigPath -NoNotify 6>$null).status | Should -Be 'OK'
            Mock -ModuleName LogBackup Test-BackupSnapshot { New-StepResult 'verify' 'ALERT' 'simulated verify failure' }
            $r = Invoke-LogBackupRun -ConfigPath $e.ConfigPath -NoNotify 6>$null
            $r.status | Should -Be 'ALERT'
            Step $r 'retention' | Should -BeNullOrEmpty
            @(Get-TestSnapshot $e.Config).Count | Should -Be 2   # the older good snapshot was NOT forgotten
        }
    }

    Context 'Retention policy' {
        It 'keeps exactly what the policy says (daily 3 + monthly 2)' {
            $e = New-Env -Retention @{ keepDaily = 3; keepWeekly = 0; keepMonthly = 2 }
            Initialize-Repo $e.Config
            $staging = Join-Path $e.Config.workDir 'staging'
            foreach ($s in $e.Config.sources) { Copy-SourceToStaging -Source $s -StagingRoot $staging -Config $e.Config | Out-Null }
            $dates = '2026-01-15', '2026-02-15', '2026-03-10', '2026-03-11', '2026-03-12', '2026-03-13'
            foreach ($d in $dates) {
                Add-Content (Join-Path $staging 'app-logs\app-2026-11-01.log') "entry for $d"
                New-BackupManifest -StagingRoot $staging -RunId "run-$d" | Out-Null
                (Invoke-ResticBackup -StagingRoot $staging -Config $e.Config -Password $script:SecurePassword -RunId "run-$d" -Time "$d 10:00:00").Status | Should -Be 'OK'
            }
            $ret = Invoke-Retention -Config $e.Config -Password $script:SecurePassword
            $ret.Status | Should -Be 'OK'
            $ret.Data.removed | Should -Be 2
            $left = (Get-TestSnapshot $e.Config | ForEach-Object { if ($_.time -is [datetime]) { $_.time.ToString('yyyy-MM-dd') } else { ([string]$_.time).Substring(0, 10) } }) | Sort-Object
            ($left -join ',') | Should -Be '2026-02-15,2026-03-11,2026-03-12,2026-03-13'
            $check = Invoke-Restic -Arguments @('check') -Config $e.Config -Password $script:SecurePassword
            $check.ExitCode | Should -Be 0   # prune left a consistent repository
        }
    }
}
