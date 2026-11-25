<#
.SYNOPSIS
    Runs PSScriptAnalyzer and the Pester suites. Used locally and in CI.
.PARAMETER Integration  Also run the integration tests (needs restic: scripts\Install-Restic.ps1 or $env:RESTIC_EXE).
#>
[CmdletBinding()]
param([switch]$Integration, [switch]$CI)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent

$pester = Get-Module Pester -ListAvailable | Where-Object { $_.Version -ge [version]'5.0.0' } | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5 or later is required: Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser -SkipPublisherCheck' }
Import-Module $pester.Path -Force
Write-Output "Pester $($pester.Version) on PowerShell $($PSVersionTable.PSVersion)"

if (Get-Module PSScriptAnalyzer -ListAvailable) {
    $findings = @(Invoke-ScriptAnalyzer -Path $root -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1'))
    $findings | Format-Table RuleName, ScriptName, Line, Message -AutoSize | Out-String -Width 220 | Write-Output
    Write-Output "PSScriptAnalyzer findings: $($findings.Count)"
    if ($findings.Count) { throw 'Fix the PSScriptAnalyzer findings first.' }
}

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.PassThru = $true
$config.Output.Verbosity = 'Detailed'
$config.Filter.ExcludeTag = if ($Integration) { @() } else { @('Integration') }
if ($CI) {
    $config.TestResult.Enabled = $true
    $config.TestResult.OutputFormat = 'JUnitXml'
    $config.TestResult.OutputPath = Join-Path $root 'TestResults\pester.xml'
}
$result = Invoke-Pester -Configuration $config
Write-Output "Passed: $($result.PassedCount)  Failed: $($result.FailedCount)  Skipped: $($result.SkippedCount)"
if ($result.FailedCount -gt 0) { exit 1 }
if ($Integration -and $result.SkippedCount -gt 0) { Write-Warning 'Integration tests were skipped: restic not found.'; exit 1 }
