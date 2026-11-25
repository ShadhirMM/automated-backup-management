<#
.SYNOPSIS
    Restores log files from the encrypted repository and proves they are intact.

.DESCRIPTION
    Restores one snapshot (default: latest) - all sources, or one source - into
    <Target>\<snapshot-id>\, then checks every restored file's SHA-256 against the
    manifest that was saved inside the same snapshot. Nothing is overwritten: the target
    folder must be empty or new.

.EXAMPLE
    .\scripts\Restore-LogBackup.ps1 -Target D:\Restore
.EXAMPLE
    .\scripts\Restore-LogBackup.ps1 -Source app-logs -Snapshot 4f1c2a9b -Target D:\Restore
.EXAMPLE
    # list snapshots first
    .\scripts\Restore-LogBackup.ps1 -List
#>
[CmdletBinding(DefaultParameterSetName = 'Restore')]
param(
    [string]$ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config\backup.config.json'),
    [Parameter(ParameterSetName = 'Restore', Mandatory)][string]$Target,
    [Parameter(ParameterSetName = 'Restore')][string]$Snapshot = 'latest',
    [Parameter(ParameterSetName = 'Restore')][string]$Source,
    [Parameter(ParameterSetName = 'List')][switch]$List
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\LogBackup\LogBackup.psd1') -Force
$config = Get-BackupConfig -Path $ConfigPath
$password = Get-RepositoryPassword -Config $config

$snapArgs = @('snapshots', '--json', '--tag', 'logbackup')
if ($PSCmdlet.ParameterSetName -eq 'Restore' -and $Snapshot -ne 'latest') { $snapArgs += $Snapshot }
$snaps = Invoke-Restic -Arguments $snapArgs -Config $config -Password $password
if ($snaps.ExitCode -ne 0) { throw "Cannot list snapshots (exit $($snaps.ExitCode)): $(Get-ResticFailureHint $snaps.ExitCode $snaps.StdErr)" }
$snapList = @(@(ConvertFrom-ResticJson $snaps.StdOut | ForEach-Object { $_ }) | Sort-Object time)
if ($List) {
    $snapList | ForEach-Object { [pscustomobject]@{ Id = $_.short_id; Time = $_.time; Host = $_.hostname; Tags = ($_.tags -join ',') } }
    return
}
if (-not $snapList) { throw "No snapshot found ($Snapshot)." }
$snap = $snapList[-1]

$dest = Join-Path $Target $snap.short_id
if ((Test-Path -LiteralPath $dest) -and (Get-ChildItem -LiteralPath $dest -Force | Select-Object -First 1)) { throw "Target $dest is not empty; choose another folder." }
$work = Join-Path $Target ("_restore-" + [guid]::NewGuid().ToString('N').Substring(0, 8))

$stagingInSnapshot = ConvertTo-ResticPath $snap.paths[0]
$restoreArgs = @('restore', $snap.id, '--target', $work)
if ($Source) { $restoreArgs += @('--include', "$stagingInSnapshot/$Source", '--include', "$stagingInSnapshot/_backup-manifest.json") }
Write-Information "Restoring snapshot $($snap.short_id) from $($snap.time)$(if ($Source) { " (source $Source)" })" -InformationAction Continue
$r = Invoke-Restic -Arguments $restoreArgs -Config $config -Password $password
if ($r.ExitCode -ne 0) { throw "restic restore failed (exit $($r.ExitCode)): $(Get-ResticFailureHint $r.ExitCode $r.StdErr)" }

try {
    $manifestFile = Get-ChildItem -LiteralPath $work -Recurse -Force | Where-Object { -not $_.PSIsContainer -and $_.Name -eq '_backup-manifest.json' } | Select-Object -First 1
    if (-not $manifestFile) { throw 'No manifest in the restored data: cannot verify.' }
    $manifest = Get-Content -LiteralPath $manifestFile.FullName -Raw | ConvertFrom-Json
    $files = @($manifest.files | Where-Object { -not $Source -or $_.source -eq $Source })
    if ($Source -and -not $files) { throw "Source '$Source' is not in snapshot $($snap.short_id)." }
    $bad = 0
    foreach ($f in $files) {
        $p = Join-Path $manifestFile.DirectoryName ($f.path -replace '/', '\')
        if (-not (Test-Path -LiteralPath $p) -or (Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash.ToLowerInvariant() -ne $f.sha256) {
            Write-Warning "NOT INTACT: $($f.path)"
            $bad++
        }
    }
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Get-ChildItem -LiteralPath $manifestFile.DirectoryName -Force | Move-Item -Destination $dest
    if ($bad) { Write-Error "$bad of $($files.Count) restored file(s) do not match the manifest. See docs/RECOVERY.md." }
    else { Write-Output "Restored $($files.Count) file(s) to $dest; all SHA-256 hashes match the backup manifest." }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
