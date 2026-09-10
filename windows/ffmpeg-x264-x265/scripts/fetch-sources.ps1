param(
    [string]$OutputDir = "",
    [switch]$Refresh
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$packageRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $packageRoot "..\..")).Path
$lockPath = Join-Path $packageRoot "build-lock.json"
$lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
$sourceRoot = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    Join-Path $repoRoot "build\sources"
} elseif ([System.IO.Path]::IsPathRooted($OutputDir)) {
    [System.IO.Path]::GetFullPath($OutputDir)
} else {
    [System.IO.Path]::GetFullPath((Join-Path $repoRoot $OutputDir))
}

New-Item -ItemType Directory -Path $sourceRoot -Force | Out-Null

foreach ($name in @($lock.components.PSObject.Properties.Name)) {
    $component = $lock.components.$name
    $destination = Join-Path $sourceRoot $name
    if (-not (Test-Path -LiteralPath (Join-Path $destination ".git"))) {
        & git clone --filter=blob:none --no-checkout $component.repository $destination
        if ($LASTEXITCODE -ne 0) {
            throw "git clone failed for $name"
        }
    } else {
        $actualRemote = (& git -C $destination remote get-url origin).Trim()
        if ($actualRemote -ne [string]$component.repository) {
            & git -C $destination remote set-url origin $component.repository
            if ($LASTEXITCODE -ne 0) {
                throw "git remote update failed for $name"
            }
        }
    }
    & git -C $destination cat-file -e "$($component.revision)^{commit}" 2>$null
    if ($LASTEXITCODE -ne 0) {
        & git -C $destination fetch origin
        if ($LASTEXITCODE -ne 0) {
            throw "git fetch failed for $name"
        }
        & git -C $destination cat-file -e "$($component.revision)^{commit}" 2>$null
        if ($LASTEXITCODE -ne 0) {
            throw "$name revision is not reachable from its official upstream: $($component.revision)"
        }
    }
    if ($Refresh) {
        & git -C $destination clean -dffx
        if ($LASTEXITCODE -ne 0) {
            throw "git clean failed for $name"
        }
    }
    & git -C $destination checkout --detach --force $component.revision
    if ($LASTEXITCODE -ne 0) {
        throw "git checkout failed for $name at $($component.revision)"
    }
    $actualRevision = (& git -C $destination rev-parse HEAD).Trim()
    if ($actualRevision -ne [string]$component.revision) {
        throw "$name revision mismatch: $actualRevision"
    }
    $licensePath = Join-Path $destination ([string]$component.licenseFile)
    if (-not (Test-Path -LiteralPath $licensePath)) {
        throw "$name license input missing: $licensePath"
    }
    Write-Host "$name $actualRevision"
}

$avcodecVersion = Get-Content -LiteralPath (
    Join-Path $sourceRoot "ffmpeg\libavcodec\version_major.h"
) -Raw -Encoding UTF8
$expectedMajor = [int]$lock.components.ffmpeg.expectedLibavcodecMajor
if ($avcodecVersion -notmatch "#define\s+LIBAVCODEC_VERSION_MAJOR\s+$expectedMajor\b") {
    throw "Pinned FFmpeg does not expose libavcodec major $expectedMajor"
}

Write-Host "Pinned sources and license inputs are ready: $sourceRoot"
