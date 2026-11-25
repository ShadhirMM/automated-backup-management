# Shared helpers for the Pester tests. Dot-source inside BeforeAll.

$script:ProjectRoot = Split-Path $PSScriptRoot -Parent
$script:ModulePath = Join-Path $script:ProjectRoot 'src\LogBackup\LogBackup.psd1'

function New-TestRoot {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('logbackup-test-' + [guid]::NewGuid().ToString('N').Substring(0, 10))
    New-Item -ItemType Directory -Path $root | Out-Null
    return (Resolve-Path $root).Path
}

function New-DemoLogFolder {
    <# Creates a folder of fake log files. #>
    param([string]$Path, [int]$Files = 3, [string]$Prefix = 'app')
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    for ($i = 1; $i -le $Files; $i++) {
        $lines = 1..(20 * $i) | ForEach-Object { "2026-11-{0:D2}T08:{1:D2}:00Z INFO $Prefix request id=$_ status=200 ms=$($_ * 3)" -f $i, ($_ % 60) }
        Set-Content -LiteralPath (Join-Path $Path "$Prefix-2026-11-$('{0:D2}' -f $i).log") -Value $lines -Encoding UTF8
    }
    New-Item -ItemType Directory -Path (Join-Path $Path 'archive') -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $Path 'archive\old.log') -Value 'archived line' -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $Path 'scratch.tmp') -Value 'temporary' -Encoding UTF8
}

function New-TestConfig {
    <# Writes a config for a temp environment and returns its path. #>
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$ResticPath = 'restic.exe',
        [object[]]$Sources,
        [hashtable]$Retention = @{ keepDaily = 30; keepWeekly = 0; keepMonthly = 0 },
        [int]$ReadDataSubsetPercent = 100,
        [int]$FullReadEveryDays = 0,
        [int]$RestoreEveryDays = 7,
        [string]$Repository,
        [hashtable]$Extra = @{}
    )
    if (-not $Sources) {
        $Sources = @(
            @{ name = 'app-logs'; type = 'path'; path = (Join-Path $Root 'src\app'); exclude = @('*.tmp'); optional = $false },
            @{ name = 'sys-logs'; type = 'path'; path = (Join-Path $Root 'src\sys'); exclude = @(); optional = $false }
        )
    }
    if (-not $Repository) { $Repository = Join-Path $Root 'repo' }
    $cfg = [ordered]@{
        jobName = 'test-backup'; hostTag = 'TESTHOST'; resticPath = $ResticPath; rclonePath = 'rclone'
        repository = $Repository; passwordFile = (Join-Path $Root 'secrets\pw.xml'); workDir = (Join-Path $Root 'work')
        cleanStagingAfterRun = $true; sources = $Sources; retention = $Retention
        verify = @{ readDataSubsetPercent = $ReadDataSubsetPercent; fullReadEveryDays = $FullReadEveryDays }
        restoreTest = @{ everyDays = $RestoreEveryDays; sampleSize = 0 }
        thresholds = @{ maxHoursSinceSuccess = 26; minFilesPerSource = 1 }
        notify = @{ webhookEnv = 'LOGBACKUP_TEST_WEBHOOK'; webhookFile = $null; onSuccess = $false }
        eventLog = @{ enabled = $false; source = 'LogBackup' }
        lockStaleHours = 6; resticTimeoutMinutes = 10
    }
    foreach ($k in $Extra.Keys) { $cfg[$k] = $Extra[$k] }
    New-Item -ItemType Directory -Path (Join-Path $Root 'config') -Force | Out-Null
    $path = Join-Path $Root 'config\backup.config.json'
    $cfg | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function ConvertTo-TestSecureString([string]$Text) {
    ConvertTo-ReadOnlySecureString -Text $Text
}

function Get-ResticExe {
    if ($env:RESTIC_EXE -and (Test-Path $env:RESTIC_EXE)) { return (Resolve-Path $env:RESTIC_EXE).Path }
    $local = Join-Path $script:ProjectRoot 'tools\bin\restic.exe'
    if (Test-Path $local) { return $local }
    return $null
}
