#Requires -Version 5.1
<#
    LogBackup: copies designated log folders into an encrypted restic repository,
    verifies the result, applies retention, tests recovery and reports
    OK / WARNING / ALERT.

    Encryption, deduplication, snapshots and repository checks are done by restic
    (AES-256 + Poly1305, https://restic.net). This module only orchestrates it.
#>
Set-StrictMode -Version 3.0

$script:StatusRank = @{ 'OK' = 0; 'SKIPPED' = 0; 'WARNING' = 1; 'ALERT' = 2 }
$script:ManifestName = '_backup-manifest.json'
$script:BackupTag = 'logbackup'

#region Configuration ---------------------------------------------------------

function Resolve-BackupPath {
    <# Expands %ENV% variables and resolves relative paths against $BaseDir. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Path, [Parameter(Mandatory)][string]$BaseDir)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }
    $expanded = [Environment]::ExpandEnvironmentVariables($Path)
    # Repository URLs (s3:, rclone:, sftp:, rest:, b2:, azure:, gs:) are not file paths.
    if ($expanded -match '^(s3|rclone|sftp|rest|b2|azure|gs|swift):') { return $expanded }
    if ([IO.Path]::IsPathRooted($expanded)) { return [IO.Path]::GetFullPath($expanded) }
    return [IO.Path]::GetFullPath((Join-Path $BaseDir $expanded))
}

function Get-Prop {
    <# Property value or $null (safe under Set-StrictMode for JSON objects with missing keys). #>
    [CmdletBinding()]
    param($Object, [Parameter(Mandatory)][string]$Name)
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Set-PropDefault {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Object, [Parameter(Mandatory)][string]$Name, $Value)
    if ($null -eq (Get-Prop $Object $Name)) { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force }
}

function Get-BackupConfig {
    <#
    .SYNOPSIS Loads and validates the JSON configuration. Throws one error listing every problem.
    .PARAMETER BaseDir Folder that relative paths are resolved against (default: the project root).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$BaseDir
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "Config file not found: $Path" }
    try { $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json }
    catch { throw "Config file is not valid JSON: $($_.Exception.Message)" }
    if ($null -eq $cfg) { throw "Config file is empty: $Path" }
    if (-not $BaseDir) { $BaseDir = Split-Path (Split-Path (Resolve-Path -LiteralPath $Path).Path -Parent) -Parent }

    $errors = New-Object System.Collections.Generic.List[string]
    foreach ($key in 'jobName', 'repository', 'resticPath', 'workDir') {
        if ([string]::IsNullOrWhiteSpace((Get-Prop $cfg $key))) { $errors.Add("'$key' is required") }
    }
    $job = Get-Prop $cfg 'jobName'
    if ($job -and $job -notmatch '^[A-Za-z0-9._-]+$') { $errors.Add("'jobName' may only contain letters, digits, '.', '_' and '-'") }
    $sources = @(Get-Prop $cfg 'sources' | Where-Object { $null -ne $_ })
    if ($sources.Count -eq 0) { $errors.Add("'sources' must list at least one source") }
    $names = @{}
    foreach ($s in $sources) {
        $n = Get-Prop $s 'name'
        if ([string]::IsNullOrWhiteSpace($n) -or $n -notmatch '^[A-Za-z0-9._-]+$') { $errors.Add("source name '$n' is missing or has invalid characters"); continue }
        if ($names.ContainsKey($n)) { $errors.Add("source name '$n' is used twice") }
        $names[$n] = $true
        switch (Get-Prop $s 'type') {
            'path' { if (-not (Get-Prop $s 'path')) { $errors.Add("source '$n': 'path' is required for type 'path'") } }
            'rclone' { if ((Get-Prop $s 'remote') -notmatch '^[^:]+:') { $errors.Add("source '$n': 'remote' must look like 'remoteName:folder'") } }
            default { $errors.Add("source '$n': type must be 'path' or 'rclone'") }
        }
    }
    $r = Get-Prop $cfg 'retention'
    if (-not $r) { $errors.Add("'retention' is required") }
    else {
        $retentionOk = $true
        foreach ($k in 'keepDaily', 'keepWeekly', 'keepMonthly') {
            $v = Get-Prop $r $k
            $isWhole = ($v -is [int] -or $v -is [long])
            if (-not $isWhole -or $v -lt 0) { $errors.Add("retention.$k must be a whole number >= 0"); $retentionOk = $false }
        }
        if ($retentionOk -and ($r.keepDaily + $r.keepWeekly + $r.keepMonthly) -eq 0) { $errors.Add('retention keeps nothing: at least one keep value must be above 0') }
    }
    $maxHours = Get-Prop (Get-Prop $cfg 'thresholds') 'maxHoursSinceSuccess'
    if ($null -ne $maxHours -and $maxHours -le 0) { $errors.Add('thresholds.maxHoursSinceSuccess must be above 0') }
    $pct = Get-Prop (Get-Prop $cfg 'verify') 'readDataSubsetPercent'
    if ($null -ne $pct -and ($pct -lt 0 -or $pct -gt 100)) { $errors.Add('verify.readDataSubsetPercent must be 0-100') }
    if ($errors.Count) { throw "Invalid config ($Path): $($errors -join '; ')" }

    # Defaults, so the rest of the module can rely on every property existing.
    Set-PropDefault $cfg 'hostTag' $env:COMPUTERNAME
    Set-PropDefault $cfg 'rclonePath' 'rclone'
    Set-PropDefault $cfg 'passwordFile' 'secrets\repo-password.xml'
    Set-PropDefault $cfg 'cleanStagingAfterRun' $true
    Set-PropDefault $cfg 'lockStaleHours' 6
    Set-PropDefault $cfg 'resticTimeoutMinutes' 120
    foreach ($section in 'verify', 'restoreTest', 'thresholds', 'notify', 'eventLog') { Set-PropDefault $cfg $section ([pscustomobject]@{}) }
    Set-PropDefault $cfg.verify 'readDataSubsetPercent' 5
    Set-PropDefault $cfg.verify 'fullReadEveryDays' 30
    Set-PropDefault $cfg.restoreTest 'everyDays' 7
    Set-PropDefault $cfg.restoreTest 'sampleSize' 0
    Set-PropDefault $cfg.thresholds 'maxHoursSinceSuccess' 26
    Set-PropDefault $cfg.thresholds 'minFilesPerSource' 1
    Set-PropDefault $cfg.notify 'webhookEnv' 'BACKUP_WEBHOOK_URL'
    if (-not $cfg.notify.PSObject.Properties['webhookFile']) { $cfg.notify | Add-Member -NotePropertyName webhookFile -NotePropertyValue $null }
    Set-PropDefault $cfg.notify 'onSuccess' $false
    Set-PropDefault $cfg.eventLog 'enabled' $false
    Set-PropDefault $cfg.eventLog 'source' 'LogBackup'

    $cfg.repository = Resolve-BackupPath $cfg.repository -BaseDir $BaseDir
    $cfg.workDir = Resolve-BackupPath $cfg.workDir -BaseDir $BaseDir
    $cfg.passwordFile = Resolve-BackupPath $cfg.passwordFile -BaseDir $BaseDir
    if ($cfg.resticPath -match '[\\/]') { $cfg.resticPath = Resolve-BackupPath $cfg.resticPath -BaseDir $BaseDir }
    if ($cfg.notify.webhookFile) { $cfg.notify.webhookFile = Resolve-BackupPath $cfg.notify.webhookFile -BaseDir $BaseDir }
    foreach ($s in $sources) {
        foreach ($k in 'path', 'remote') { if (-not $s.PSObject.Properties[$k]) { $s | Add-Member -NotePropertyName $k -NotePropertyValue $null } }
        if ($s.type -eq 'path') { $s.path = Resolve-BackupPath $s.path -BaseDir $BaseDir }
        Set-PropDefault $s 'exclude' @()
        Set-PropDefault $s 'optional' $false
    }
    $cfg | Add-Member -NotePropertyName BaseDir -NotePropertyValue $BaseDir -Force
    return $cfg
}

#endregion

#region Secrets ----------------------------------------------------------------

function ConvertFrom-SecureStringToPlain {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][Security.SecureString]$SecureString)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
}

function Save-ProtectedSecret {
    <# Saves a SecureString with Windows DPAPI (only the same user on the same machine can read it). #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][Security.SecureString]$Secret, [Parameter(Mandatory)][string]$Path)
    if ($PSCmdlet.ShouldProcess($Path, 'Save DPAPI-protected secret')) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        $Secret | Export-Clixml -LiteralPath $Path
    }
}

function Get-ProtectedSecret {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $secure = Import-Clixml -LiteralPath $Path
    if ($secure -isnot [Security.SecureString]) { throw "Secret file $Path does not contain a SecureString." }
    return ConvertFrom-SecureStringToPlain $secure
}

function ConvertTo-ReadOnlySecureString {
    [CmdletBinding()]
    [OutputType([Security.SecureString])]
    param([Parameter(Mandatory)][string]$Text)
    $secure = New-Object Security.SecureString
    foreach ($ch in $Text.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    return $secure
}

function Get-RepositoryPassword {
    <#
    .SYNOPSIS Repository password as a SecureString: env RESTIC_PASSWORD (CI / service accounts)
    first, else the DPAPI file. It is turned into plain text only inside Invoke-Restic, for the
    restic child process environment.
    #>
    [CmdletBinding()]
    [OutputType([Security.SecureString])]
    param([Parameter(Mandatory)]$Config)
    if ($env:RESTIC_PASSWORD) { return ConvertTo-ReadOnlySecureString $env:RESTIC_PASSWORD }
    if (Test-Path -LiteralPath $Config.passwordFile) {
        $secure = Import-Clixml -LiteralPath $Config.passwordFile
        if ($secure -is [Security.SecureString]) { return $secure }
        throw "Password file $($Config.passwordFile) does not contain a SecureString."
    }
    throw "Repository password not found. Run scripts\Initialize-BackupRepository.ps1 (creates $($Config.passwordFile)) or set RESTIC_PASSWORD."
}

function Get-WebhookUrl {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Config)
    $envName = $Config.notify.webhookEnv
    if ($envName) {
        $v = [Environment]::GetEnvironmentVariable($envName)
        if ($v) { return $v }
    }
    if ($Config.notify.webhookFile) { return Get-ProtectedSecret -Path $Config.notify.webhookFile }
    return $null
}

#endregion

#region Logging, lock, state ----------------------------------------------------

function Write-BackupLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARNING', 'ERROR')][string]$Level = 'INFO',
        [string]$LogDir
    )
    $line = '{0} {1,-7} {2}' -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ssZ'), $Level, $Message
    if ($LogDir) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
        Add-Content -LiteralPath (Join-Path $LogDir ('backup-{0}.log' -f (Get-Date).ToUniversalTime().ToString('yyyyMMdd'))) -Value $line -Encoding UTF8
    }
    Write-Information $line -InformationAction Continue
}

function Enter-BackupLock {
    <# Prevents overlapping runs. A lock older than StaleHours is taken over (crashed run). #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [double]$StaleHours = 6)
    New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
    if (Test-Path -LiteralPath $Path) {
        $age = (Get-Date) - (Get-Item -LiteralPath $Path).LastWriteTime
        if ($age.TotalHours -lt $StaleHours) {
            throw "Another backup run is in progress (lock $Path, $([int]$age.TotalMinutes) min old)."
        }
        Write-Warning "Taking over a stale lock ($([int]$age.TotalHours) h old)."
    }
    Set-Content -LiteralPath $Path -Value (@{ pid = $PID; started = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json -Compress) -Encoding UTF8
}

function Exit-BackupLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
}

function Get-BackupState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $state = [pscustomobject]@{ lastSuccessUtc = $null; lastRestoreTestUtc = $null; lastFullReadUtc = $null; lastSnapshotId = $null }
    if (Test-Path -LiteralPath $Path) {
        $saved = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $state | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    }
    return $state
}

function Save-BackupState {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$State)
    if ($PSCmdlet.ShouldProcess($Path, 'Save state')) {
        New-Item -ItemType Directory -Path (Split-Path $Path -Parent) -Force | Out-Null
        $tmp = "$Path.tmp"
        $State | ConvertTo-Json | Set-Content -LiteralPath $tmp -Encoding UTF8
        Move-Item -LiteralPath $tmp -Destination $Path -Force
    }
}

function ConvertTo-UtcDate {
    [CmdletBinding()]
    [OutputType([datetime])]
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }
    return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
}

function Test-IsDue {
    <# True when $LastUtc is empty or older than $EveryDays. EveryDays 0 = never due. #>
    [CmdletBinding()]
    [OutputType([bool])]
    param($LastUtc, [double]$EveryDays, [datetime]$NowUtc = (Get-Date).ToUniversalTime())
    if ($EveryDays -le 0) { return $false }
    if (-not $LastUtc) { return $true }
    return (($NowUtc - (ConvertTo-UtcDate $LastUtc)).TotalDays -ge $EveryDays)
}

function Get-HoursSince {
    [CmdletBinding()]
    [OutputType([double])]
    param($LastUtc, [datetime]$NowUtc = (Get-Date).ToUniversalTime())
    if (-not $LastUtc) { return [double]::PositiveInfinity }
    return ($NowUtc - (ConvertTo-UtcDate $LastUtc)).TotalHours
}

#endregion

#region restic process wrapper --------------------------------------------------

function ConvertTo-ProcessArgument {
    <# Quotes one argument for a Windows command line (CommandLineToArgvW rules). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string]$Value)
    if ($Value -eq '') { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"'
    $escaped = $escaped -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

function ConvertTo-ResticPath {
    <# C:\Work\staging -> /C/Work/staging (how restic names Windows paths inside snapshots). #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string]$Path)
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -match '^([A-Za-z]):\\?(.*)$') {
        $rest = $Matches[2] -replace '\\', '/'
        if ($rest) { return "/$($Matches[1])/$rest" }
        return "/$($Matches[1])"
    }
    return ($full -replace '\\', '/')
}

function Invoke-Restic {
    <#
    .SYNOPSIS Runs restic with the repository and password passed ONLY through the child
    process environment (never on the command line, never in this session's environment).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][Security.SecureString]$Password,
        [int]$TimeoutMinutes = 0
    )
    if (-not $TimeoutMinutes) { $TimeoutMinutes = [int]$Config.resticTimeoutMinutes }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Config.resticPath
    $psi.Arguments = (@($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ })) -join ' '
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    foreach ($name in 'RESTIC_PASSWORD_FILE', 'RESTIC_PASSWORD_COMMAND', 'RESTIC_REPOSITORY_FILE') {
        if ($psi.EnvironmentVariables.ContainsKey($name)) { $psi.EnvironmentVariables.Remove($name) }
    }
    $psi.EnvironmentVariables['RESTIC_REPOSITORY'] = $Config.repository
    $psi.EnvironmentVariables['RESTIC_PASSWORD'] = ConvertFrom-SecureStringToPlain $Password
    $psi.EnvironmentVariables['RESTIC_CACHE_DIR'] = Join-Path $Config.workDir 'cache'

    try { $proc = [Diagnostics.Process]::Start($psi) }
    catch { throw "Cannot start restic at '$($Config.resticPath)': $($_.Exception.Message). Run scripts\Install-Restic.ps1." }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutMinutes * 60 * 1000)) {
        try { $proc.Kill() } catch { Write-Verbose "kill failed: $_" }
        throw "restic $($Arguments[0]) timed out after $TimeoutMinutes minutes."
    }
    $proc.WaitForExit()
    [pscustomobject]@{
        Command  = "restic $($Arguments[0])"
        ExitCode = $proc.ExitCode
        StdOut   = $outTask.Result
        StdErr   = $errTask.Result
    }
}

function Get-ResticFailureHint {
    <# Turns a restic exit code / error text into a root-cause hint for the alert. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([int]$ExitCode, [string]$StdErr)
    $e = "$StdErr"
    if ($ExitCode -eq 12 -or $e -match 'wrong password|no key found') { return 'Wrong repository password: check the DPAPI password file belongs to this user/machine, or RESTIC_PASSWORD.' }
    if ($ExitCode -eq 10 -or $e -match 'repository does not exist|unable to open config file|Is there a repository at') { return 'Repository not found or not reachable: check the drive/share is connected and the repository path; never re-init over an existing repository.' }
    if ($ExitCode -eq 11 -or $e -match 'unable to create lock|repository is already locked') { return "Repository is locked by another process; if no backup is running, run 'restic unlock'." }
    if ($e -match 'Pack ID does not match|ciphertext verification failed|data corrupted|invalid data returned|error for tree|is damaged') { return 'Repository data is damaged: do NOT prune; run restic check --read-data, then follow docs/RECOVERY.md (repair section).' }
    if ($e -match 'no space left|not enough space|disk full') { return 'Backup target is out of space: free space or shorten retention.' }
    if ($e -match 'Access is denied|permission denied') { return 'Access denied: check the task account can read the sources and write the repository.' }
    if ($ExitCode -eq 3) { return 'Some source files could not be read (locked or deleted during backup); snapshot is incomplete.' }
    return 'See the restic error text in the log for details.'
}

function ConvertFrom-ResticJson {
    <# Parses newline-delimited JSON output, ignoring non-JSON lines. #>
    [CmdletBinding()]
    param([string]$Text)
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t.StartsWith('{') -or $t.StartsWith('[')) {
            try { $t | ConvertFrom-Json } catch { Write-Verbose "skip non-JSON line: $t" }
        }
    }
}

#endregion

#region Steps ----------------------------------------------------------------------

function New-StepResult {
    [CmdletBinding()]
    param([string]$Name, [ValidateSet('OK', 'WARNING', 'ALERT', 'SKIPPED')][string]$Status, [string]$Message, [string]$Hint = '', [hashtable]$Data = @{})
    [pscustomobject]@{ Name = $Name; Status = $Status; Message = $Message; Hint = $Hint; Data = $Data }
}

function Get-OverallStatus {
    [CmdletBinding()]
    [OutputType([string])]
    param([object[]]$Steps)
    $worst = 'OK'
    foreach ($s in @($Steps)) {
        if ($null -ne $s -and $script:StatusRank[$s.Status] -gt $script:StatusRank[$worst]) { $worst = $s.Status }
    }
    return $worst
}

function Copy-SourceToStaging {
    <#
    .SYNOPSIS Copies one source into staging\<name>. Local/UNC folders use robocopy /MIR;
    cloud folders use `rclone copy --checksum`. Staging gives a stable copy, so the
    manifest and the snapshot describe exactly the same bytes even while logs are being written.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source, [Parameter(Mandatory)][string]$StagingRoot, [Parameter(Mandatory)]$Config)
    # robocopy/rclone report progress and errors on stderr; with a caller's 'Stop' preference that
    # would throw before the exit code is read. Exit codes decide the result here.
    $ErrorActionPreference = 'Continue'
    $dest = Join-Path $StagingRoot $Source.name
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    $missingStatus = if ($Source.optional) { 'WARNING' } else { 'ALERT' }

    if ($Source.type -eq 'path') {
        if (-not (Test-Path -LiteralPath $Source.path -PathType Container)) {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue   # never back up an old copy as if it were new
            return New-StepResult "copy:$($Source.name)" $missingStatus "Source folder not found: $($Source.path)" 'Check the path exists and the drive/share is connected, and that the task account can read it.'
        }
        $rcArgs = @($Source.path, $dest, '/MIR', '/R:2', '/W:5', '/NP', '/NFL', '/NDL', '/NJH', '/NJS', '/XJ')
        if (@($Source.exclude).Count) { $rcArgs += '/XF'; $rcArgs += @($Source.exclude) }
        $out = & robocopy.exe @rcArgs 2>&1
        $code = $LASTEXITCODE
        if ($code -ge 8) {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
            return New-StepResult "copy:$($Source.name)" 'ALERT' "robocopy failed (exit $code): $(($out | Select-Object -Last 3) -join ' ')" 'Check permissions and free space in the work folder.'
        }
    }
    else {
        $rcArgs = @('copy', $Source.remote, $dest, '--checksum', '--retries', '3', '--low-level-retries', '10')
        foreach ($x in @($Source.exclude)) { $rcArgs += @('--exclude', $x) }
        $out = & $Config.rclonePath @rcArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Remove-Item -LiteralPath $dest -Recurse -Force -ErrorAction SilentlyContinue
            return New-StepResult "copy:$($Source.name)" $missingStatus "rclone copy failed (exit $LASTEXITCODE): $(($out | Select-Object -Last 3) -join ' ')" "Check the rclone remote '$($Source.remote.Split(':')[0])' with 'rclone lsd' (token expired? folder renamed?)."
        }
    }
    $files = @(Get-ChildItem -LiteralPath $dest -Recurse -File -Force)
    [long]$bytes = 0
    foreach ($f in $files) { $bytes += $f.Length }
    $min = [int]$Config.thresholds.minFilesPerSource
    if ($files.Count -lt $min) {
        return New-StepResult "copy:$($Source.name)" 'WARNING' "Only $($files.Count) file(s) staged (minimum $min)." 'An empty log folder usually means logging stopped or the path changed.' @{ files = $files.Count; bytes = $bytes }
    }
    return New-StepResult "copy:$($Source.name)" 'OK' "$($files.Count) file(s), $([math]::Round($bytes / 1MB, 2)) MB staged" '' @{ files = $files.Count; bytes = $bytes }
}

function New-BackupManifest {
    <# SHA-256 of every staged file. Saved inside the staging root, so it travels in the snapshot. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$StagingRoot, [Parameter(Mandatory)][string]$RunId, [string]$JobName = 'log-backup')
    $root = [IO.Path]::GetFullPath($StagingRoot).TrimEnd('\')
    $entries = foreach ($f in Get-ChildItem -LiteralPath $root -Recurse -File -Force | Sort-Object FullName) {
        if ($f.Name -eq $script:ManifestName -and $f.DirectoryName.TrimEnd('\') -eq $root) { continue }
        $rel = $f.FullName.Substring($root.Length + 1) -replace '\\', '/'
        [pscustomobject]@{
            source = $rel.Split('/')[0]
            path   = $rel
            size   = $f.Length
            sha256 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    $entries = @($entries)
    [long]$total = 0
    foreach ($e in $entries) { $total += $e.size }
    $manifest = [pscustomobject]@{
        jobName    = $JobName
        runId      = $RunId
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        fileCount  = $entries.Count
        totalBytes = [long]$total
        files      = $entries
    }
    $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $root $script:ManifestName) -Encoding UTF8
    return $manifest
}

function Invoke-ResticBackup {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$StagingRoot, [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][Security.SecureString]$Password,
        [Parameter(Mandatory)][string]$RunId, [string]$Time
    )
    $resticArgs = @('backup', $StagingRoot, '--json', '--tag', $script:BackupTag, '--tag', "job:$($Config.jobName)", '--tag', "run:$RunId", '--host', $Config.hostTag)
    if ($Time) { $resticArgs += @('--time', $Time) }
    $r = Invoke-Restic -Arguments $resticArgs -Config $Config -Password $Password
    $summary = ConvertFrom-ResticJson $r.StdOut | Where-Object { $_.PSObject.Properties['message_type'] -and $_.message_type -eq 'summary' } | Select-Object -Last 1
    if ($r.ExitCode -eq 0 -and $summary) {
        return New-StepResult 'backup' 'OK' ("Snapshot {0}: {1} file(s), {2} new, {3} changed" -f $summary.snapshot_id.Substring(0, 8), $summary.total_files_processed, $summary.files_new, $summary.files_changed) '' @{ snapshotId = $summary.snapshot_id; summary = $summary }
    }
    if ($r.ExitCode -eq 3 -and $summary) {
        return New-StepResult 'backup' 'WARNING' "Snapshot $($summary.snapshot_id.Substring(0, 8)) is incomplete: some files could not be read." (Get-ResticFailureHint 3 $r.StdErr) @{ snapshotId = $summary.snapshot_id; summary = $summary }
    }
    return New-StepResult 'backup' 'ALERT' "restic backup failed (exit $($r.ExitCode)): $(($r.StdErr -split "`n" | Where-Object { $_ } | Select-Object -Last 2) -join ' ')" (Get-ResticFailureHint $r.ExitCode $r.StdErr)
}

function Compare-ManifestToSnapshot {
    <# Every manifest file must be in the snapshot listing with the same size, and nothing extra. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Nodes, [Parameter(Mandatory)][string]$StagingResticPath)
    $prefix = $StagingResticPath.TrimEnd('/') + '/'
    $inSnapshot = @{}
    foreach ($n in $Nodes) {
        if ($n.type -eq 'file' -and $n.path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            $rel = $n.path.Substring($prefix.Length)
            if ($rel -ne $script:ManifestName) { $inSnapshot[$rel] = [long]$n.size }
        }
    }
    $problems = New-Object System.Collections.Generic.List[string]
    foreach ($f in @($Manifest.files)) {
        if (-not $inSnapshot.ContainsKey($f.path)) { $problems.Add("missing: $($f.path)"); continue }
        if ($inSnapshot[$f.path] -ne [long]$f.size) { $problems.Add("size differs: $($f.path) (manifest $($f.size), snapshot $($inSnapshot[$f.path]))") }
        $inSnapshot.Remove($f.path)
    }
    foreach ($extra in $inSnapshot.Keys) { $problems.Add("not in manifest: $extra") }
    return , $problems.ToArray()
}

function Test-BackupSnapshot {
    <# Verify: the snapshot exists and matches the manifest; the repository passes restic check. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SnapshotId, [Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][string]$StagingRoot,
        [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][Security.SecureString]$Password, [ValidateSet('none', 'subset', 'full')][string]$ReadData = 'none'
    )
    $ls = Invoke-Restic -Arguments @('ls', $SnapshotId, '--json') -Config $Config -Password $Password
    if ($ls.ExitCode -ne 0) {
        return New-StepResult 'verify' 'ALERT' "Snapshot $SnapshotId cannot be listed (exit $($ls.ExitCode))." (Get-ResticFailureHint $ls.ExitCode $ls.StdErr)
    }
    $nodes = @(ConvertFrom-ResticJson $ls.StdOut | Where-Object { $_.PSObject.Properties['type'] -and $_.PSObject.Properties['path'] })
    $problems = Compare-ManifestToSnapshot -Manifest $Manifest -Nodes $nodes -StagingResticPath (ConvertTo-ResticPath $StagingRoot)
    if ($problems.Count) {
        return New-StepResult 'verify' 'ALERT' "Snapshot does not match the manifest: $(($problems | Select-Object -First 5) -join '; ')" 'Files changed or were lost during backup. Re-run the backup; if it repeats, check the source disk.' @{ problems = $problems }
    }
    $checkArgs = @('check')
    switch ($ReadData) {
        'subset' { $checkArgs += "--read-data-subset=$($Config.verify.readDataSubsetPercent)%" }
        'full' { $checkArgs += '--read-data' }
    }
    $check = Invoke-Restic -Arguments $checkArgs -Config $Config -Password $Password
    if ($check.ExitCode -ne 0) {
        return New-StepResult 'verify' 'ALERT' "restic check failed (exit $($check.ExitCode)): $(($check.StdErr + ' ' + $check.StdOut) -split "`n" | Where-Object { $_ -match 'error|fail|damage|match' } | Select-Object -First 3)" (Get-ResticFailureHint $check.ExitCode ($check.StdErr + $check.StdOut))
    }
    $what = switch ($ReadData) { 'subset' { "structure + $($Config.verify.readDataSubsetPercent)% of data read back" } 'full' { 'structure + all data read back' } default { 'structure' } }
    return New-StepResult 'verify' 'OK' "$($Manifest.fileCount) file(s) match the manifest; repository check passed ($what)." '' @{ readData = $ReadData }
}

function Get-RetentionArgumentList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)]$Config)
    $a = @('forget', '--json', '--tag', $script:BackupTag, '--host', $Config.hostTag)
    if ($Config.retention.keepDaily -gt 0) { $a += @('--keep-daily', [string]$Config.retention.keepDaily) }
    if ($Config.retention.keepWeekly -gt 0) { $a += @('--keep-weekly', [string]$Config.retention.keepWeekly) }
    if ($Config.retention.keepMonthly -gt 0) { $a += @('--keep-monthly', [string]$Config.retention.keepMonthly) }
    return , $a
}

function Invoke-Retention {
    <# forget per policy, then prune unreferenced data. Never runs after a failed verify. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][Security.SecureString]$Password)
    $f = Invoke-Restic -Arguments (Get-RetentionArgumentList $Config) -Config $Config -Password $Password
    if ($f.ExitCode -ne 0) {
        return New-StepResult 'retention' 'WARNING' "restic forget failed (exit $($f.ExitCode))." (Get-ResticFailureHint $f.ExitCode $f.StdErr)
    }
    $groups = @(ConvertFrom-ResticJson $f.StdOut)
    $removed = 0; $kept = 0
    foreach ($g in $groups) {
        foreach ($grp in @($g)) {
            if ($grp.PSObject.Properties['remove'] -and $grp.remove) { $removed += @($grp.remove).Count }
            if ($grp.PSObject.Properties['keep'] -and $grp.keep) { $kept += @($grp.keep).Count }
        }
    }
    if ($removed -gt 0) {
        $p = Invoke-Restic -Arguments @('prune') -Config $Config -Password $Password
        if ($p.ExitCode -ne 0) {
            return New-StepResult 'retention' 'WARNING' "Removed $removed snapshot(s) but prune failed (exit $($p.ExitCode))." (Get-ResticFailureHint $p.ExitCode $p.StdErr) @{ removed = $removed; kept = $kept }
        }
    }
    $policy = 'daily {0}, weekly {1}, monthly {2}' -f $Config.retention.keepDaily, $Config.retention.keepWeekly, $Config.retention.keepMonthly
    return New-StepResult 'retention' 'OK' "Kept $kept snapshot(s), removed $removed ($policy)." '' @{ removed = $removed; kept = $kept }
}

function Invoke-RestoreTest {
    <#
    .SYNOPSIS Recovery test: restores a snapshot into a temporary folder, re-hashes the
    files and compares them with the manifest stored in the same snapshot. Cleans up afterwards.
    .PARAMETER SampleSize 0 = verify every file, N = a random sample of N files.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config, [Parameter(Mandatory)][Security.SecureString]$Password, [string]$SnapshotId = 'latest',
        [int]$SampleSize = 0, [string]$TempRoot = [IO.Path]::GetTempPath()
    )
    $target = Join-Path $TempRoot ("restore-test-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
    try {
        $snapArgs = @('restore', $SnapshotId, '--target', $target)
        if ($SnapshotId -eq 'latest') { $snapArgs += @('--tag', $script:BackupTag, '--host', $Config.hostTag) }
        $r = Invoke-Restic -Arguments $snapArgs -Config $Config -Password $Password
        if ($r.ExitCode -ne 0) {
            return New-StepResult 'restore-test' 'ALERT' "Restore failed (exit $($r.ExitCode))." (Get-ResticFailureHint $r.ExitCode $r.StdErr)
        }
        $restored = @(Get-ChildItem -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue)
        $manifestFile = $restored | Where-Object { -not $_.PSIsContainer -and $_.Name -eq $script:ManifestName } | Select-Object -First 1
        if (-not $manifestFile) {
            $sample = ($restored | Where-Object { -not $_.PSIsContainer } | Select-Object -First 4 | ForEach-Object { "$($_.Name) ($($_.Attributes))" }) -join ', '
            $tail = (("$($r.StdErr)`n$($r.StdOut)" -split "`n" | Where-Object { $_.Trim() }) | Select-Object -Last 3) -join ' | '
            return New-StepResult 'restore-test' 'ALERT' "Restored snapshot has no manifest; cannot prove the files are intact. Restored items: $($restored.Count) [$sample]. restic: $tail" 'The snapshot was not made by this tool, or it is damaged.'
        }
        $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
        $root = $manifestFile.DirectoryName
        $files = @($manifest.files)
        if ($SampleSize -gt 0 -and $files.Count -gt $SampleSize) { $files = @($files | Get-Random -Count $SampleSize) }
        $bad = New-Object System.Collections.Generic.List[string]
        foreach ($f in $files) {
            $p = Join-Path $root ($f.path -replace '/', '\')
            if (-not (Test-Path -LiteralPath $p)) { $bad.Add("missing: $($f.path)"); continue }
            $h = (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($h -ne $f.sha256) { $bad.Add("hash mismatch: $($f.path)") }
        }
        if ($bad.Count) {
            return New-StepResult 'restore-test' 'ALERT' "Recovery test FAILED: $($bad.Count) of $($files.Count) file(s) differ ($(($bad | Select-Object -First 3) -join '; '))." 'Restored data does not match what was backed up. Run restic check --read-data and see docs/RECOVERY.md.' @{ problems = $bad.ToArray(); checked = $files.Count }
        }
        return New-StepResult 'restore-test' 'OK' "Restored snapshot $($manifest.runId): $($files.Count) file(s) verified by SHA-256." '' @{ checked = $files.Count; runId = $manifest.runId }
    }
    finally {
        if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

#endregion

#region Notification ---------------------------------------------------------------

function Format-BackupReportText {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)]$Report)
    $lines = @("[$($Report.status)] Log backup '$($Report.jobName)' on $($Report.host) ($($Report.mode), run $($Report.runId))")
    foreach ($s in @($Report.steps)) {
        if ($s.Status -eq 'SKIPPED') { continue }
        $line = "  [{0,-7}] {1}: {2}" -f $s.Status, $s.Name, $s.Message
        if ($s.Hint -and $s.Status -ne 'OK') { $line += "`n            -> $($s.Hint)" }
        $lines += $line
    }
    return ($lines -join "`n")
}

function Send-BackupNotification {
    <# Posts the report to a webhook (Slack/Teams-compatible 'text' + structured fields). 3 attempts; never throws. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([string]$Uri, [Parameter(Mandatory)]$Report, [int]$Attempts = 3, [int]$DelaySeconds = 5)
    if (-not $Uri) { return 'not-configured' }
    $payload = [ordered]@{
        text   = Format-BackupReportText $Report
        status = $Report.status
        job    = $Report.jobName
        host   = $Report.host
        runId  = $Report.runId
        steps  = @($Report.steps | ForEach-Object { [ordered]@{ name = $_.Name; status = $_.Status; message = $_.Message; hint = $_.Hint } })
    } | ConvertTo-Json -Depth 5
    for ($i = 1; $i -le $Attempts; $i++) {
        try {
            Invoke-RestMethod -Uri $Uri -Method Post -Body ([Text.Encoding]::UTF8.GetBytes($payload)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 20 | Out-Null
            return 'sent'
        }
        catch {
            Write-Warning "Webhook attempt $i failed: $($_.Exception.Message)"
            if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
        }
    }
    return 'failed'
}

function Write-BackupEventLog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)]$Report)
    if (-not $Config.eventLog.enabled) { return 'disabled' }
    try {
        $type = switch ($Report.status) { 'ALERT' { 'Error' } 'WARNING' { 'Warning' } default { 'Information' } }
        $id = switch ($Report.status) { 'ALERT' { 3 } 'WARNING' { 2 } default { 1 } }
        Write-EventLog -LogName Application -Source $Config.eventLog.source -EntryType $type -EventId $id -Message (Format-BackupReportText $Report) -ErrorAction Stop
        return 'written'
    }
    catch {
        Write-Warning "Event log write failed (create the source once as admin: New-EventLog -LogName Application -Source $($Config.eventLog.source)): $($_.Exception.Message)"
        return 'failed'
    }
}

#endregion

#region Orchestration --------------------------------------------------------------

function Get-ExitCodeForStatus {
    [CmdletBinding()]
    [OutputType([int])]
    param([string]$Status)
    switch ($Status) { 'OK' { 0 } 'WARNING' { 1 } 'ALERT' { 2 } default { 3 } }
}

function Invoke-LogBackupRun {
    <#
    .SYNOPSIS One run. Modes:
      Backup      stage -> manifest -> backup -> verify -> retention -> recovery test (when due) -> staleness
      RestoreTest recovery test only (latest snapshot)
      Verify      restic check with full data read
      StaleCheck  only checks the time since the last good backup (watchdog task)
    Returns the report object; ExitCode: 0 OK, 1 WARNING, 2 ALERT, 3 could not run (config/lock/password).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [ValidateSet('Backup', 'RestoreTest', 'Verify', 'StaleCheck')][string]$Mode = 'Backup',
        [switch]$ForceRestoreTest,
        [switch]$NoNotify,
        [string]$BaseDir,
        [string]$BackupTime
    )
    $runId = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ') + '-' + ([guid]::NewGuid().ToString('N').Substring(0, 6))
    $steps = New-Object System.Collections.Generic.List[object]
    $report = [pscustomobject]@{
        jobName = ''; host = $env:COMPUTERNAME; mode = $Mode; runId = $runId; startedUtc = (Get-Date).ToUniversalTime().ToString('o')
        finishedUtc = $null; status = 'ALERT'; exitCode = 3; steps = $steps; snapshotId = $null; notification = $null; reportPath = $null
    }
    $config = $null; $logDir = $null; $lockPath = $null; $lockHeld = $false

    try {
        $config = Get-BackupConfig -Path $ConfigPath -BaseDir $BaseDir
        $report.jobName = $config.jobName
        $report.host = $config.hostTag
        $logDir = Join-Path $config.workDir 'logs'
        $statePath = Join-Path $config.workDir 'state\state.json'
        $lockPath = Join-Path $config.workDir 'backup.lock'
        Write-BackupLog "Run $runId started (mode $Mode)" -LogDir $logDir
        $state = Get-BackupState -Path $statePath

        if ($Mode -eq 'StaleCheck') {
            $steps.Add((Get-StalenessStep -State $state -Config $config))
        }
        else {
            Enter-BackupLock -Path $lockPath -StaleHours $config.lockStaleHours
            $lockHeld = $true
            $password = Get-RepositoryPassword -Config $config
            if (-not (Test-Path -LiteralPath $config.resticPath) -and -not (Get-Command $config.resticPath -ErrorAction SilentlyContinue)) {
                throw "restic not found at '$($config.resticPath)'. Run scripts\Install-Restic.ps1."
            }

            if ($Mode -eq 'Backup') {
                Invoke-BackupPipeline -Config $config -Password $password -RunId $runId -State $state -Steps $steps -Report $report -ForceRestoreTest:$ForceRestoreTest -BackupTime $BackupTime -LogDir $logDir
                $steps.Add((Get-StalenessStep -State $state -Config $config))
            }
            elseif ($Mode -eq 'RestoreTest') {
                $rt = Invoke-RestoreTest -Config $config -Password $password -SampleSize ([int]$config.restoreTest.sampleSize) -TempRoot (Join-Path $config.workDir 'tmp')
                $steps.Add($rt)
                if ($rt.Status -eq 'OK') { $state.lastRestoreTestUtc = (Get-Date).ToUniversalTime().ToString('o') }
            }
            elseif ($Mode -eq 'Verify') {
                $check = Invoke-Restic -Arguments @('check', '--read-data') -Config $config -Password $password
                if ($check.ExitCode -eq 0) {
                    $steps.Add((New-StepResult 'verify' 'OK' 'Full repository check passed (all data read back).'))
                    $state.lastFullReadUtc = (Get-Date).ToUniversalTime().ToString('o')
                }
                else { $steps.Add((New-StepResult 'verify' 'ALERT' "restic check --read-data failed (exit $($check.ExitCode))." (Get-ResticFailureHint $check.ExitCode ($check.StdErr + $check.StdOut)))) }
            }
            Save-BackupState -Path $statePath -State $state
        }
        $report.status = Get-OverallStatus $steps
        $report.exitCode = Get-ExitCodeForStatus $report.status
    }
    catch {
        $msg = $_.Exception.Message
        $hint = if ($msg -match 'in progress') { 'Wait for the other run, or remove the lock if no backup is running.' }
        elseif ($msg -match 'password') { 'Create the password file with scripts\Initialize-BackupRepository.ps1 as the task account.' }
        elseif ($msg -match 'restic not found') { 'Run scripts\Install-Restic.ps1.' }
        else { 'Fix the configuration, then run with -WhatIf/-Mode StaleCheck to test.' }
        $steps.Add((New-StepResult 'run' 'ALERT' "Run could not start: $msg" $hint))
        $report.status = 'ALERT'
        $report.exitCode = 3
        if ($lockHeld -and $msg -match 'in progress') { $lockHeld = $false }
    }
    finally {
        if ($lockHeld -and $lockPath) { Exit-BackupLock -Path $lockPath }
    }

    $report.finishedUtc = (Get-Date).ToUniversalTime().ToString('o')
    $report.steps = $steps.ToArray()
    foreach ($s in $report.steps) {
        $lvl = switch ($s.Status) { 'ALERT' { 'ERROR' } 'WARNING' { 'WARNING' } default { 'INFO' } }
        $text = "$($s.Name): $($s.Status) - $($s.Message)"
        if ($s.Hint -and $s.Status -ne 'OK') { $text += " | hint: $($s.Hint)" }
        Write-BackupLog $text -Level $lvl -LogDir $logDir
    }

    if ($config) {
        $reportDir = Join-Path $config.workDir 'reports'
        New-Item -ItemType Directory -Path $reportDir -Force | Out-Null
        $report.reportPath = Join-Path $reportDir "run-$runId.json"
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $report.reportPath -Encoding UTF8
        $null = Write-BackupEventLog -Config $config -Report $report
        $shouldNotify = $report.status -ne 'OK' -or $config.notify.onSuccess
        if ($NoNotify) { $report.notification = 'suppressed' }
        elseif ($shouldNotify) { $report.notification = Send-BackupNotification -Uri (Get-WebhookUrl -Config $config) -Report $report }
        else { $report.notification = 'not-needed' }
        Write-BackupLog "Run $runId finished: $($report.status) (exit $($report.exitCode)), notification: $($report.notification)" -Level $(if ($report.status -eq 'OK') { 'INFO' } elseif ($report.status -eq 'WARNING') { 'WARNING' } else { 'ERROR' }) -LogDir $logDir
    }
    return $report
}

function Get-StalenessStep {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State, [Parameter(Mandatory)]$Config)
    $hours = Get-HoursSince $State.lastSuccessUtc
    $max = [double]$Config.thresholds.maxHoursSinceSuccess
    if ([double]::IsInfinity($hours)) {
        return New-StepResult 'staleness' 'ALERT' 'No successful backup has ever been recorded.' 'Run a backup now and check its result.'
    }
    if ($hours -gt $max) {
        return New-StepResult 'staleness' 'ALERT' ("Last good backup was {0:N1} h ago (limit {1} h)." -f $hours, $max) 'Check the scheduled task is enabled and its last result, and read the latest run report.'
    }
    return New-StepResult 'staleness' 'OK' ("Last good backup {0:N1} h ago." -f $hours)
}

function Invoke-BackupPipeline {
    [CmdletBinding()]
    param($Config, [Security.SecureString]$Password, [string]$RunId, $State, $Steps, $Report, [switch]$ForceRestoreTest, [string]$BackupTime, [string]$LogDir)
    $staging = Join-Path $Config.workDir 'staging'
    if (Test-Path -LiteralPath $staging) {
        # Remove folders of sources that are no longer configured.
        $names = @($Config.sources | ForEach-Object { $_.name })
        Get-ChildItem -LiteralPath $staging -Directory | Where-Object { $names -notcontains $_.Name } | Remove-Item -Recurse -Force
    }
    New-Item -ItemType Directory -Path $staging -Force | Out-Null
    try {
        $staged = 0
        foreach ($src in $Config.sources) {
            $step = Copy-SourceToStaging -Source $src -StagingRoot $staging -Config $Config
            $Steps.Add($step)
            if ($step.Data.ContainsKey('files')) { $staged++ }
            Write-BackupLog "$($step.Name): $($step.Status) - $($step.Message)" -LogDir $LogDir
        }
        if ($staged -eq 0) {
            $Steps.Add((New-StepResult 'backup' 'ALERT' 'Nothing to back up: every source failed.' 'Fix the sources listed above.'))
            return
        }
        $manifest = New-BackupManifest -StagingRoot $staging -RunId $RunId -JobName $Config.jobName
        Write-BackupLog "Manifest: $($manifest.fileCount) file(s), $($manifest.totalBytes) bytes" -LogDir $LogDir

        $backup = Invoke-ResticBackup -StagingRoot $staging -Config $Config -Password $Password -RunId $RunId -Time $BackupTime
        $Steps.Add($backup)
        if ($backup.Status -eq 'ALERT') { return }
        $snapshotId = $backup.Data.snapshotId
        $Report.snapshotId = $snapshotId
        $State.lastSnapshotId = $snapshotId

        $readData = 'subset'
        if (Test-IsDue -LastUtc $State.lastFullReadUtc -EveryDays $Config.verify.fullReadEveryDays) { $readData = 'full' }
        elseif ([int]$Config.verify.readDataSubsetPercent -eq 0) { $readData = 'none' }
        $verify = Test-BackupSnapshot -SnapshotId $snapshotId -Manifest $manifest -StagingRoot $staging -Config $Config -Password $Password -ReadData $readData
        $Steps.Add($verify)
        if ($verify.Status -ne 'OK') { return }   # never delete old snapshots when the new one is not proven good
        if ($readData -eq 'full') { $State.lastFullReadUtc = (Get-Date).ToUniversalTime().ToString('o') }
        if ($backup.Status -eq 'OK') { $State.lastSuccessUtc = (Get-Date).ToUniversalTime().ToString('o') }

        $Steps.Add((Invoke-Retention -Config $Config -Password $Password))

        if ($ForceRestoreTest -or (Test-IsDue -LastUtc $State.lastRestoreTestUtc -EveryDays $Config.restoreTest.everyDays)) {
            $rt = Invoke-RestoreTest -Config $Config -Password $Password -SnapshotId $snapshotId -SampleSize ([int]$Config.restoreTest.sampleSize) -TempRoot (Join-Path $Config.workDir 'tmp')
            $Steps.Add($rt)
            if ($rt.Status -eq 'OK') { $State.lastRestoreTestUtc = (Get-Date).ToUniversalTime().ToString('o') }
        }
        else {
            $Steps.Add((New-StepResult 'restore-test' 'SKIPPED' "Not due (every $($Config.restoreTest.everyDays) day(s))."))
        }
    }
    finally {
        if ($Config.cleanStagingAfterRun -and (Test-Path -LiteralPath $staging)) {
            Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

#endregion

Export-ModuleMember -Function @(
    'Get-BackupConfig', 'Get-Prop', 'Resolve-BackupPath', 'Get-RepositoryPassword', 'Get-WebhookUrl', 'Save-ProtectedSecret', 'Get-ProtectedSecret', 'ConvertFrom-SecureStringToPlain', 'ConvertTo-ReadOnlySecureString',
    'Write-BackupLog', 'ConvertTo-UtcDate', 'Enter-BackupLock', 'Exit-BackupLock', 'Get-BackupState', 'Save-BackupState', 'Test-IsDue', 'Get-HoursSince',
    'ConvertTo-ProcessArgument', 'ConvertTo-ResticPath', 'Invoke-Restic', 'Get-ResticFailureHint', 'ConvertFrom-ResticJson',
    'New-StepResult', 'Get-OverallStatus', 'Copy-SourceToStaging', 'New-BackupManifest', 'Invoke-ResticBackup',
    'Compare-ManifestToSnapshot', 'Test-BackupSnapshot', 'Get-RetentionArgumentList', 'Invoke-Retention', 'Invoke-RestoreTest',
    'Format-BackupReportText', 'Send-BackupNotification', 'Write-BackupEventLog', 'Get-ExitCodeForStatus',
    'Invoke-LogBackupRun', 'Get-StalenessStep'
)
