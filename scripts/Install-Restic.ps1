<#
.SYNOPSIS
    Downloads the official restic release for Windows into tools\bin and verifies it.

.DESCRIPTION
    1. Downloads restic_<version>_windows_amd64.zip and SHA256SUMS from the official
       GitHub release (https://github.com/restic/restic/releases).
    2. Checks the zip's SHA-256 against SHA256SUMS AND against the hash pinned in this
       script for known versions (so a tampered release page is also caught).
    3. Extracts restic.exe to tools\bin (git-ignored) and runs `restic version`.

.EXAMPLE
    .\scripts\Install-Restic.ps1
.EXAMPLE
    .\scripts\Install-Restic.ps1 -Version 0.20.0 -Destination C:\Tools\restic
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version = '0.20.0',
    [string]$Destination = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools\bin')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# SHA-256 of restic_<version>_windows_amd64.zip, recorded when the version was approved.
$PinnedHashes = @{
    '0.20.0' = 'bba9061c3dce081701ab353ec8cb73a78be73b71a538aad560f2d1067602b7fe'
}

$zipName = "restic_${Version}_windows_amd64.zip"
$base = "https://github.com/restic/restic/releases/download/v$Version"
$temp = Join-Path ([IO.Path]::GetTempPath()) ("restic-install-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp | Out-Null

try {
    $zip = Join-Path $temp $zipName
    $sums = Join-Path $temp 'SHA256SUMS'
    Write-Information "Downloading $zipName" -InformationAction Continue
    Invoke-WebRequest -Uri "$base/$zipName" -OutFile $zip -UseBasicParsing
    Invoke-WebRequest -Uri "$base/SHA256SUMS" -OutFile $sums -UseBasicParsing

    $actual = (Get-FileHash -Path $zip -Algorithm SHA256).Hash.ToLowerInvariant()
    $line = Get-Content $sums | Where-Object { $_ -match "\s\*?$([regex]::Escape($zipName))$" } | Select-Object -First 1
    if (-not $line) { throw "$zipName is not listed in SHA256SUMS." }
    $expected = ($line -split '\s+')[0].ToLowerInvariant()
    if ($actual -ne $expected) { throw "Checksum mismatch for ${zipName}: expected $expected, got $actual." }

    $pinned = $PinnedHashes[$Version]
    if ($pinned -and $pinned -notlike '__PIN*') {
        if ($actual -ne $pinned) { throw "Hash differs from the pinned hash for v$Version. Do not use this download." }
        Write-Information "SHA-256 matches SHA256SUMS and the pinned hash." -InformationAction Continue
    }
    else {
        Write-Warning "No pinned hash for v$Version; verified against SHA256SUMS only. Pin $actual in this script after review."
    }

    if ($PSCmdlet.ShouldProcess($Destination, "Install restic $Version")) {
        Expand-Archive -Path $zip -DestinationPath $temp -Force
        $exe = Get-ChildItem -Path $temp -Filter 'restic*.exe' | Select-Object -First 1
        if (-not $exe) { throw 'restic executable not found in the archive.' }
        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        $target = Join-Path $Destination 'restic.exe'
        Copy-Item -Path $exe.FullName -Destination $target -Force
        $versionText = & $target version
        Write-Output "Installed: $versionText"
        Write-Output "Path: $target"
    }
}
finally {
    Remove-Item -Path $temp -Recurse -Force -ErrorAction SilentlyContinue
}
