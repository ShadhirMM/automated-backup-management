#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Unit tests: no restic needed. A tiny fake restic (.cmd) is used where a process is required.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Import-Module $script:ModulePath -Force
    $script:Root = New-TestRoot
    $env:RESTIC_PASSWORD = $null
}

AfterAll {
    Remove-Item -LiteralPath $script:Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Module LogBackup -ErrorAction SilentlyContinue
}

Describe 'Configuration' {
    It 'loads the shipped example config and resolves paths against the project root' {
        $cfg = Get-BackupConfig -Path (Join-Path $script:ProjectRoot 'config\backup.config.json')
        $cfg.sources.Count | Should -Be 3
        $cfg.workDir | Should -Be (Join-Path $script:ProjectRoot 'work')
        $cfg.resticPath | Should -Be (Join-Path $script:ProjectRoot 'tools\bin\restic.exe')
        $cfg.repository | Should -Be 'E:\Backups\log-repo'
        $cfg.retention.keepDaily | Should -Be 14
    }

    It 'leaves repository URLs alone and expands environment variables' {
        $env:LB_TEST_DIR = 'C:\LbTest'
        Resolve-BackupPath 'rclone:gdrive:backups' -BaseDir 'C:\x' | Should -Be 'rclone:gdrive:backups'
        Resolve-BackupPath 's3:s3.amazonaws.com/bucket' -BaseDir 'C:\x' | Should -Be 's3:s3.amazonaws.com/bucket'
        Resolve-BackupPath '%LB_TEST_DIR%\logs' -BaseDir 'C:\x' | Should -Be 'C:\LbTest\logs'
        Resolve-BackupPath 'work' -BaseDir 'C:\x' | Should -Be 'C:\x\work'
    }

    It 'fills in defaults for optional sections' {
        $p = Join-Path $script:Root 'min.json'
        '{"jobName":"j","repository":"r","resticPath":"restic","workDir":"w","sources":[{"name":"a","type":"path","path":"C:\\a"}],"retention":{"keepDaily":7,"keepWeekly":0,"keepMonthly":0}}' | Set-Content $p
        $cfg = Get-BackupConfig -Path $p -BaseDir 'C:\base'
        $cfg.verify.readDataSubsetPercent | Should -Be 5
        $cfg.restoreTest.everyDays | Should -Be 7
        $cfg.thresholds.maxHoursSinceSuccess | Should -Be 26
        $cfg.sources[0].optional | Should -BeFalse
        $cfg.resticPath | Should -Be 'restic'   # bare command name stays a command name
    }

    It 'rejects <case>' -ForEach @(
        @{ case = 'no sources'; json = '{"jobName":"j","repository":"r","resticPath":"x","workDir":"w","sources":[],"retention":{"keepDaily":1,"keepWeekly":0,"keepMonthly":0}}'; msg = 'at least one source' }
        @{ case = 'duplicate source names'; json = '{"jobName":"j","repository":"r","resticPath":"x","workDir":"w","sources":[{"name":"a","type":"path","path":"p"},{"name":"a","type":"path","path":"q"}],"retention":{"keepDaily":1,"keepWeekly":0,"keepMonthly":0}}'; msg = 'used twice' }
        @{ case = 'unknown source type'; json = '{"jobName":"j","repository":"r","resticPath":"x","workDir":"w","sources":[{"name":"a","type":"ftp","path":"p"}],"retention":{"keepDaily":1,"keepWeekly":0,"keepMonthly":0}}'; msg = "type must be 'path' or 'rclone'" }
        @{ case = 'bad rclone remote'; json = '{"jobName":"j","repository":"r","resticPath":"x","workDir":"w","sources":[{"name":"a","type":"rclone","remote":"nocolon"}],"retention":{"keepDaily":1,"keepWeekly":0,"keepMonthly":0}}'; msg = 'remoteName:folder' }
        @{ case = 'retention keeping nothing'; json = '{"jobName":"j","repository":"r","resticPath":"x","workDir":"w","sources":[{"name":"a","type":"path","path":"p"}],"retention":{"keepDaily":0,"keepWeekly":0,"keepMonthly":0}}'; msg = 'keeps nothing' }
        @{ case = 'negative retention'; json = '{"jobName":"j","repository":"r","resticPath":"x","workDir":"w","sources":[{"name":"a","type":"path","path":"p"}],"retention":{"keepDaily":-1,"keepWeekly":0,"keepMonthly":0}}'; msg = 'keepDaily must be' }
        @{ case = 'missing repository'; json = '{"jobName":"j","resticPath":"x","workDir":"w","sources":[{"name":"a","type":"path","path":"p"}],"retention":{"keepDaily":1,"keepWeekly":0,"keepMonthly":0}}'; msg = "'repository' is required" }
        @{ case = 'invalid JSON'; json = '{"jobName": '; msg = 'not valid JSON' }
    ) {
        $p = Join-Path $script:Root "bad-$([guid]::NewGuid().ToString('N')).json"
        Set-Content -LiteralPath $p -Value $json
        { Get-BackupConfig -Path $p -BaseDir 'C:\b' } | Should -Throw "*$msg*"
    }
}

Describe 'Path and argument helpers' {
    It 'quotes process arguments: <value>' -ForEach @(
        @{ value = 'abc'; expected = 'abc' }
        @{ value = 'a b'; expected = '"a b"' }
        @{ value = 'a"b'; expected = '"a\"b"' }
        @{ value = 'C:\x y\'; expected = '"C:\x y\\"' }
        @{ value = ''; expected = '""' }
    ) {
        ConvertTo-ProcessArgument $value | Should -BeExactly $expected
    }

    It 'converts Windows paths to restic snapshot paths' {
        ConvertTo-ResticPath 'C:\Work\staging' | Should -Be '/C/Work/staging'
        ConvertTo-ResticPath 'C:\Work\staging\' | Should -Be '/C/Work/staging'
        ConvertTo-ResticPath 'D:\' | Should -Be '/D'
    }

    It 'parses newline-delimited JSON and skips other lines' {
        $out = "noise`n{""message_type"":""status""}`n{""message_type"":""summary"",""snapshot_id"":""abc""}`n"
        $objs = @(ConvertFrom-ResticJson $out)
        $objs.Count | Should -Be 2
        $objs[1].snapshot_id | Should -Be 'abc'
    }
}

Describe 'Staging and manifest' {
    BeforeAll {
        $script:SrcRoot = Join-Path $script:Root 'stage-src'
        New-DemoLogFolder -Path (Join-Path $script:SrcRoot 'app') -Files 3
        $script:Cfg = [pscustomobject]@{ rclonePath = 'rclone'; thresholds = [pscustomobject]@{ minFilesPerSource = 1 } }
    }

    It 'copies a local folder with robocopy and honours excludes' {
        $staging = Join-Path $script:Root 'staging1'
        $src = [pscustomobject]@{ name = 'app'; type = 'path'; path = (Join-Path $script:SrcRoot 'app'); exclude = @('*.tmp'); optional = $false }
        $r = Copy-SourceToStaging -Source $src -StagingRoot $staging -Config $script:Cfg
        $r.Status | Should -Be 'OK'
        $r.Data.files | Should -Be 4
        Test-Path (Join-Path $staging 'app\scratch.tmp') | Should -BeFalse
        Test-Path (Join-Path $staging 'app\archive\old.log') | Should -BeTrue
    }

    It 'mirrors deletions (a log removed at the source is removed from staging)' {
        $staging = Join-Path $script:Root 'staging-mir'
        $srcDir = Join-Path $script:Root 'mir-src'
        New-DemoLogFolder -Path $srcDir -Files 2
        $src = [pscustomobject]@{ name = 'm'; type = 'path'; path = $srcDir; exclude = @(); optional = $false }
        Copy-SourceToStaging -Source $src -StagingRoot $staging -Config $script:Cfg | Out-Null
        Remove-Item (Join-Path $srcDir 'app-2026-11-01.log')
        Copy-SourceToStaging -Source $src -StagingRoot $staging -Config $script:Cfg | Out-Null
        Test-Path (Join-Path $staging 'm\app-2026-11-01.log') | Should -BeFalse
    }

    It 'raises ALERT for a missing required source, WARNING for an optional one, and drops stale staged data' {
        $staging = Join-Path $script:Root 'staging2'
        New-Item -ItemType Directory -Path (Join-Path $staging 'gone') -Force | Out-Null
        Set-Content (Join-Path $staging 'gone\old.log') 'stale'
        $req = [pscustomobject]@{ name = 'gone'; type = 'path'; path = 'C:\does\not\exist\xyz'; exclude = @(); optional = $false }
        $r = Copy-SourceToStaging -Source $req -StagingRoot $staging -Config $script:Cfg
        $r.Status | Should -Be 'ALERT'
        $r.Message | Should -Match 'not found'
        $r.Hint | Should -Match 'path exists'
        Test-Path (Join-Path $staging 'gone') | Should -BeFalse
        $opt = [pscustomobject]@{ name = 'opt'; type = 'path'; path = 'C:\does\not\exist\xyz'; exclude = @(); optional = $true }
        (Copy-SourceToStaging -Source $opt -StagingRoot $staging -Config $script:Cfg).Status | Should -Be 'WARNING'
    }

    It 'warns when a source has fewer files than the minimum' {
        $empty = Join-Path $script:Root 'empty-src'
        New-Item -ItemType Directory -Path $empty -Force | Out-Null
        $src = [pscustomobject]@{ name = 'e'; type = 'path'; path = $empty; exclude = @(); optional = $false }
        $r = Copy-SourceToStaging -Source $src -StagingRoot (Join-Path $script:Root 'staging3') -Config $script:Cfg
        $r.Status | Should -Be 'WARNING'
        $r.Message | Should -Match 'Only 0 file'
    }

    It 'stages cloud folders with rclone and reports rclone failures with a hint' {
        $okFake = Join-Path $script:Root 'rclone-ok.cmd'
        Set-Content $okFake "@echo off`r`necho cloud log line>""%~3\cloud.log""`r`nexit /b 0" -Encoding ASCII
        $badFake = Join-Path $script:Root 'rclone-bad.cmd'
        Set-Content $badFake "@echo off`r`necho Failed to create file system: didn't find section in config file 1>&2`r`nexit /b 1" -Encoding ASCII
        $src = [pscustomobject]@{ name = 'cloud'; type = 'rclone'; remote = 'gdrive-logs:IT/Audit'; exclude = @(); optional = $false }
        $cfgOk = [pscustomobject]@{ rclonePath = $okFake; thresholds = [pscustomobject]@{ minFilesPerSource = 1 } }
        $ok = Copy-SourceToStaging -Source $src -StagingRoot (Join-Path $script:Root 'staging4') -Config $cfgOk
        $ok.Status | Should -Be 'OK'
        Test-Path (Join-Path $script:Root 'staging4\cloud\cloud.log') | Should -BeTrue
        $cfgBad = [pscustomobject]@{ rclonePath = $badFake; thresholds = [pscustomobject]@{ minFilesPerSource = 1 } }
        $bad = Copy-SourceToStaging -Source $src -StagingRoot (Join-Path $script:Root 'staging5') -Config $cfgBad
        $bad.Status | Should -Be 'ALERT'
        $bad.Hint | Should -Match "rclone remote 'gdrive-logs'"
    }

    It 'writes a SHA-256 manifest of every staged file (but not of itself)' {
        $staging = Join-Path $script:Root 'staging1'
        $m = New-BackupManifest -StagingRoot $staging -RunId 'run-1' -JobName 'j'
        $m.fileCount | Should -Be 4
        $entry = $m.files | Where-Object { $_.path -eq 'app/archive/old.log' }
        $entry.sha256 | Should -Be ((Get-FileHash (Join-Path $staging 'app\archive\old.log') -Algorithm SHA256).Hash.ToLowerInvariant())
        $entry.source | Should -Be 'app'
        Test-Path (Join-Path $staging '_backup-manifest.json') | Should -BeTrue
        (New-BackupManifest -StagingRoot $staging -RunId 'run-2').fileCount | Should -Be 4   # re-run ignores the old manifest
    }
}

Describe 'Manifest vs snapshot comparison' {
    BeforeAll {
        $script:M = [pscustomobject]@{ files = @(
                [pscustomobject]@{ path = 'app/a.log'; size = 10 },
                [pscustomobject]@{ path = 'app/b.log'; size = 20 }) }
        function Node($p, $size, $type = 'file') { [pscustomobject]@{ type = $type; path = "/C/w/staging/$p"; size = $size } }
    }
    It 'passes when every file is present with the same size' {
        $nodes = @((Node 'app' 0 'dir'), (Node 'app/a.log' 10), (Node 'app/b.log' 20), (Node '_backup-manifest.json' 99))
        (Compare-ManifestToSnapshot -Manifest $script:M -Nodes $nodes -StagingResticPath '/C/w/staging').Count | Should -Be 0
    }
    It 'reports missing, resized and unexpected files' {
        $nodes = @((Node 'app/a.log' 11), (Node 'app/c.log' 5))
        $p = Compare-ManifestToSnapshot -Manifest $script:M -Nodes $nodes -StagingResticPath '/C/w/staging'
        $p | Should -Contain 'size differs: app/a.log (manifest 10, snapshot 11)'
        $p | Should -Contain 'missing: app/b.log'
        $p | Should -Contain 'not in manifest: app/c.log'
    }
    It 'ignores files outside the staging folder' {
        $nodes = @((Node 'app/a.log' 10), (Node 'app/b.log' 20), [pscustomobject]@{ type = 'file'; path = '/C/other/x.log'; size = 1 })
        (Compare-ManifestToSnapshot -Manifest $script:M -Nodes $nodes -StagingResticPath '/C/w/staging').Count | Should -Be 0
    }
}

Describe 'Status, hints, schedule maths' {
    It 'overall status is the worst step' {
        Get-OverallStatus @((New-StepResult a OK x), (New-StepResult b SKIPPED x)) | Should -Be 'OK'
        Get-OverallStatus @((New-StepResult a OK x), (New-StepResult b WARNING x)) | Should -Be 'WARNING'
        Get-OverallStatus @((New-StepResult a WARNING x), (New-StepResult b ALERT x), (New-StepResult c OK x)) | Should -Be 'ALERT'
    }
    It 'maps exit codes to <status>' -ForEach @(@{ status = 'OK'; code = 0 }, @{ status = 'WARNING'; code = 1 }, @{ status = 'ALERT'; code = 2 }) {
        Get-ExitCodeForStatus $status | Should -Be $code
    }
    It 'gives a root-cause hint for <case>' -ForEach @(
        @{ case = 'wrong password'; code = 12; err = 'Fatal: wrong password or no key found'; hint = 'Wrong repository password' }
        @{ case = 'missing repository'; code = 10; err = 'Fatal: repository does not exist'; hint = 'Repository not found' }
        @{ case = 'old restic missing repo'; code = 1; err = 'Fatal: unable to open config file: Is there a repository at the following location?'; hint = 'Repository not found' }
        @{ case = 'lock'; code = 11; err = 'unable to create lock in backend: repository is already locked'; hint = 'restic unlock' }
        @{ case = 'damaged data'; code = 1; err = 'Pack ID does not match, want 1a2b, got 3c4d'; hint = 'damaged' }
        @{ case = 'disk full'; code = 1; err = 'write: no space left on device'; hint = 'out of space' }
        @{ case = 'incomplete snapshot'; code = 3; err = ''; hint = 'could not be read' }
    ) {
        Get-ResticFailureHint -ExitCode $code -StdErr $err | Should -Match $hint
    }
    It 'works out when a task is due (string and DateTime inputs)' {
        $now = [datetime]::new(2026, 11, 26, 12, 0, 0, [DateTimeKind]::Utc)
        Test-IsDue -LastUtc $null -EveryDays 7 -NowUtc $now | Should -BeTrue
        Test-IsDue -LastUtc '2026-11-20T12:00:00Z' -EveryDays 7 -NowUtc $now | Should -BeFalse
        Test-IsDue -LastUtc '2026-11-19T12:00:00Z' -EveryDays 7 -NowUtc $now | Should -BeTrue
        Test-IsDue -LastUtc ([datetime]::new(2026, 11, 1, 0, 0, 0, [DateTimeKind]::Utc)) -EveryDays 7 -NowUtc $now | Should -BeTrue
        Test-IsDue -LastUtc $null -EveryDays 0 -NowUtc $now | Should -BeFalse
        Get-HoursSince '2026-11-26T10:30:00Z' -NowUtc $now | Should -Be 1.5
        [double]::IsInfinity((Get-HoursSince $null -NowUtc $now)) | Should -BeTrue
    }
    It 'builds retention arguments only for non-zero keeps' {
        $cfg = [pscustomobject]@{ hostTag = 'H'; retention = [pscustomobject]@{ keepDaily = 14; keepWeekly = 0; keepMonthly = 12 } }
        $a = Get-RetentionArgumentList $cfg
        ($a -join ' ') | Should -Be 'forget --json --tag logbackup --host H --keep-daily 14 --keep-monthly 12'
    }
}

Describe 'Lock and state' {
    It 'blocks a second run and releases on exit' {
        $lock = Join-Path $script:Root 'lock\backup.lock'
        Enter-BackupLock -Path $lock
        { Enter-BackupLock -Path $lock } | Should -Throw '*in progress*'
        Exit-BackupLock -Path $lock
        Test-Path $lock | Should -BeFalse
    }
    It 'takes over a stale lock' {
        $lock = Join-Path $script:Root 'lock\stale.lock'
        New-Item -ItemType File -Path $lock -Force | Out-Null
        (Get-Item $lock).LastWriteTime = (Get-Date).AddHours(-10)
        { Enter-BackupLock -Path $lock -StaleHours 6 -WarningAction SilentlyContinue } | Should -Not -Throw
        Exit-BackupLock -Path $lock
    }
    It 'saves and reloads state atomically' {
        $p = Join-Path $script:Root 'state\s.json'
        $s = Get-BackupState -Path $p
        $s.lastSuccessUtc | Should -BeNullOrEmpty
        $s.lastSuccessUtc = '2026-11-26T01:00:00.0000000Z'
        Save-BackupState -Path $p -State $s
        Test-Path "$p.tmp" | Should -BeFalse
        [string](ConvertTo-UtcDate (Get-BackupState -Path $p).lastSuccessUtc).ToString('o') | Should -Be '2026-11-26T01:00:00.0000000Z'
    }
}

Describe 'Secrets' {
    AfterEach { $env:RESTIC_PASSWORD = $null; $env:LOGBACKUP_TEST_WEBHOOK = $null }
    It 'prefers RESTIC_PASSWORD, else reads the DPAPI file, else explains what to do' {
        $cfg = [pscustomobject]@{ passwordFile = (Join-Path $script:Root 'secrets\pw.xml') }
        { Get-RepositoryPassword -Config $cfg } | Should -Throw '*Initialize-BackupRepository*'
        Save-ProtectedSecret -Secret (ConvertTo-TestSecureString 'dpapi-secret-value-123') -Path $cfg.passwordFile
        ConvertFrom-SecureStringToPlain (Get-RepositoryPassword -Config $cfg) | Should -Be 'dpapi-secret-value-123'
        (Get-Content $cfg.passwordFile -Raw) | Should -Not -Match 'dpapi-secret-value-123'   # encrypted at rest
        $env:RESTIC_PASSWORD = 'from-env'
        ConvertFrom-SecureStringToPlain (Get-RepositoryPassword -Config $cfg) | Should -Be 'from-env'
    }
    It 'reads the webhook from the configured environment variable' {
        $cfg = [pscustomobject]@{ notify = [pscustomobject]@{ webhookEnv = 'LOGBACKUP_TEST_WEBHOOK'; webhookFile = $null } }
        Get-WebhookUrl -Config $cfg | Should -BeNullOrEmpty
        $env:LOGBACKUP_TEST_WEBHOOK = 'https://hooks.example/abc'
        Get-WebhookUrl -Config $cfg | Should -Be 'https://hooks.example/abc'
    }
}

Describe 'restic process wrapper (fake restic)' {
    BeforeAll {
        $script:Fake = Join-Path $script:Root 'fake-restic.cmd'
        Set-Content $script:Fake "@echo off`r`necho REPO=%RESTIC_REPOSITORY%`r`necho PW=%RESTIC_PASSWORD%`r`necho ARGS=%*`r`necho problem 1>&2`r`nexit /b 12" -Encoding ASCII
        $script:FakeCfg = [pscustomobject]@{ resticPath = $script:Fake; repository = 'D:\repo with space'; workDir = $script:Root; resticTimeoutMinutes = 1 }
    }
    It 'passes repository and password only through the child environment' {
        $r = Invoke-Restic -Arguments @('backup', 'C:\some dir') -Config $script:FakeCfg -Password (ConvertTo-TestSecureString 'child-only-secret')
        $r.ExitCode | Should -Be 12
        $r.StdOut | Should -Match 'REPO=D:\\repo with space'
        $r.StdOut | Should -Match 'PW=child-only-secret'
        $r.StdOut | Should -Match 'ARGS=backup "C:\\some dir"'
        ($r.StdOut -split "`n" | Where-Object { $_ -like 'ARGS=*' }) | Should -Not -Match 'child-only-secret'
        $r.StdErr | Should -Match 'problem'
        $env:RESTIC_PASSWORD | Should -BeNullOrEmpty   # this session is untouched
    }
    It 'explains a missing restic binary' {
        $cfg = [pscustomobject]@{ resticPath = 'C:\nope\restic.exe'; repository = 'r'; workDir = $script:Root; resticTimeoutMinutes = 1 }
        { Invoke-Restic -Arguments @('version') -Config $cfg -Password (ConvertTo-TestSecureString 'x') } | Should -Throw '*Install-Restic*'
    }
}

Describe 'Notifications' {
    BeforeAll {
        $script:Report = [pscustomobject]@{
            status = 'ALERT'; jobName = 'log-backup'; host = 'LOGSRV01'; mode = 'Backup'; runId = 'r1'
            steps = @(
                (New-StepResult 'copy:app-logs' 'OK' '12 file(s) staged'),
                (New-StepResult 'backup' 'ALERT' 'restic backup failed (exit 12)' 'Wrong repository password: check ...'),
                (New-StepResult 'restore-test' 'SKIPPED' 'Not due'))
        }
    }
    It 'formats a readable message with hints for failed steps only' {
        $t = Format-BackupReportText $script:Report
        $t | Should -Match "^\[ALERT\] Log backup 'log-backup' on LOGSRV01"
        $t | Should -Match '\[ALERT  \] backup: restic backup failed'
        $t | Should -Match '-> Wrong repository password'
        $t | Should -Not -Match 'restore-test'
    }
    It 'posts JSON with text, status and steps' {
        Mock -ModuleName LogBackup Invoke-RestMethod { }
        Send-BackupNotification -Uri 'https://hooks.example/x' -Report $script:Report | Should -Be 'sent'
        Should -Invoke -ModuleName LogBackup Invoke-RestMethod -Times 1 -ParameterFilter {
            $json = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            $Uri -eq 'https://hooks.example/x' -and $json.status -eq 'ALERT' -and $json.text.StartsWith('[ALERT]') -and $json.steps.Count -eq 3
        }
    }
    It 'retries 3 times, then reports failure without throwing' {
        Mock -ModuleName LogBackup Invoke-RestMethod { throw 'connection refused' }
        Mock -ModuleName LogBackup Start-Sleep { }
        Send-BackupNotification -Uri 'https://hooks.example/x' -Report $script:Report -WarningAction SilentlyContinue | Should -Be 'failed'
        Should -Invoke -ModuleName LogBackup Invoke-RestMethod -Times 3 -Exactly
    }
    It 'does nothing when no webhook is configured' {
        Send-BackupNotification -Uri $null -Report $script:Report | Should -Be 'not-configured'
    }
}

Describe 'Run orchestration (no restic needed)' {
    BeforeEach {
        $script:Env = Join-Path $script:Root ('run-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
        New-DemoLogFolder -Path (Join-Path $script:Env 'src\app')
        New-DemoLogFolder -Path (Join-Path $script:Env 'src\sys') -Prefix 'sys'
        $script:CfgPath = New-TestConfig -Root $script:Env -ResticPath (Join-Path $script:Root 'fake-restic.cmd')
        $script:Cfg = Get-BackupConfig -Path $script:CfgPath
    }
    AfterEach { $env:RESTIC_PASSWORD = $null; $env:LOGBACKUP_TEST_WEBHOOK = $null }

    It 'StaleCheck: ALERT when no backup was ever recorded' {
        $r = Invoke-LogBackupRun -ConfigPath $script:CfgPath -Mode StaleCheck -NoNotify 6>$null
        $r.status | Should -Be 'ALERT'
        $r.exitCode | Should -Be 2
        $r.steps[0].Message | Should -Match 'No successful backup'
    }
    It 'StaleCheck: OK when recent, ALERT when older than the limit' {
        $statePath = Join-Path $script:Cfg.workDir 'state\state.json'
        Save-BackupState -Path $statePath -State ([pscustomobject]@{ lastSuccessUtc = (Get-Date).ToUniversalTime().AddHours(-2).ToString('o') })
        (Invoke-LogBackupRun -ConfigPath $script:CfgPath -Mode StaleCheck -NoNotify 6>$null).status | Should -Be 'OK'
        Save-BackupState -Path $statePath -State ([pscustomobject]@{ lastSuccessUtc = (Get-Date).ToUniversalTime().AddHours(-30).ToString('o') })
        $r = Invoke-LogBackupRun -ConfigPath $script:CfgPath -Mode StaleCheck -NoNotify 6>$null
        $r.status | Should -Be 'ALERT'
        $r.steps[0].Message | Should -Match 'limit 26 h'
    }
    It 'exit 3 with a hint when the password is missing, and writes a JSON report' {
        $r = Invoke-LogBackupRun -ConfigPath $script:CfgPath -NoNotify 6>$null
        $r.exitCode | Should -Be 3
        $r.steps[-1].Hint | Should -Match 'Initialize-BackupRepository'
        Test-Path $r.reportPath | Should -BeTrue
        (Get-Content $r.reportPath -Raw | ConvertFrom-Json).status | Should -Be 'ALERT'
    }
    It 'exit 3 when another run holds the lock, and leaves that lock alone' {
        $env:RESTIC_PASSWORD = 'x'
        $lock = Join-Path $script:Cfg.workDir 'backup.lock'
        Enter-BackupLock -Path $lock
        $r = Invoke-LogBackupRun -ConfigPath $script:CfgPath -NoNotify 6>$null
        $r.exitCode | Should -Be 3
        $r.steps[-1].Message | Should -Match 'in progress'
        Test-Path $lock | Should -BeTrue
        Exit-BackupLock -Path $lock
    }
    It 'exit 3 for an invalid config (no report, no crash)' {
        $bad = Join-Path $script:Env 'bad.json'
        Set-Content $bad '{}'
        $r = Invoke-LogBackupRun -ConfigPath $bad -NoNotify 6>$null
        $r.exitCode | Should -Be 3
        $r.steps[0].Message | Should -Match 'Invalid config'
    }
    It 'ALERT from restic is reported with the hint, and the webhook is called' {
        $env:RESTIC_PASSWORD = 'wrong'
        $env:LOGBACKUP_TEST_WEBHOOK = 'https://hooks.example/run'
        Mock -ModuleName LogBackup Invoke-RestMethod { }
        $r = Invoke-LogBackupRun -ConfigPath $script:CfgPath 6>$null   # fake restic exits 12 = wrong password
        $r.status | Should -Be 'ALERT'
        $r.exitCode | Should -Be 2
        ($r.steps | Where-Object Name -eq 'backup').Hint | Should -Match 'Wrong repository password'
        $r.notification | Should -Be 'sent'
        Should -Invoke -ModuleName LogBackup Invoke-RestMethod -Times 1
        Test-Path (Join-Path $script:Cfg.workDir 'backup.lock') | Should -BeFalse
        Test-Path (Join-Path $script:Cfg.workDir 'staging') | Should -BeFalse   # unencrypted copy removed
        (Get-BackupState -Path (Join-Path $script:Cfg.workDir 'state\state.json')).lastSuccessUtc | Should -BeNullOrEmpty
    }
    It 'does not send a webhook for OK runs unless onSuccess is set' {
        Save-BackupState -Path (Join-Path $script:Cfg.workDir 'state\state.json') -State ([pscustomobject]@{ lastSuccessUtc = (Get-Date).ToUniversalTime().ToString('o') })
        $env:LOGBACKUP_TEST_WEBHOOK = 'https://hooks.example/run'
        Mock -ModuleName LogBackup Invoke-RestMethod { }
        (Invoke-LogBackupRun -ConfigPath $script:CfgPath -Mode StaleCheck 6>$null).notification | Should -Be 'not-needed'
        Should -Invoke -ModuleName LogBackup Invoke-RestMethod -Times 0
    }
    It 'writes a daily log file' {
        Invoke-LogBackupRun -ConfigPath $script:CfgPath -Mode StaleCheck -NoNotify 6>$null | Out-Null
        $log = Get-ChildItem (Join-Path $script:Cfg.workDir 'logs') -Filter 'backup-*.log' | Select-Object -First 1
        Get-Content $log.FullName -Raw | Should -Match 'staleness: ALERT'
    }
}
