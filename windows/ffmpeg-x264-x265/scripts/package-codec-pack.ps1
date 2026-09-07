param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$Architecture,
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [Parameter(Mandatory = $true)]
    [string]$RuntimeDir,
    [Parameter(Mandatory = $true)]
    [string]$BuildManifestPath,
    [string]$SourceRoot = "",
    [string]$OutputDir = "",
    [string]$NsisCompilerPath = "",
    [switch]$RequireNsis,
    [switch]$PlanOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Resolve-FullPath {
    param([string]$BasePath, [string]$Path)
    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
}

function Assert-SafeChildPath {
    param([string]$Parent, [string]$Child)
    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [System.IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside output directory: $childFull"
    }
}

function Copy-IfDifferent {
    param([string]$Source, [string]$Destination)
    if ([System.IO.Path]::GetFullPath($Source) -ne [System.IO.Path]::GetFullPath($Destination)) {
        Copy-Item -LiteralPath $Source -Destination $Destination -Force
    }
}

function Get-PeMachine {
    param([string]$Path)
    $stream = [System.IO.File]::Open(
        $Path,
        [System.IO.FileMode]::Open,
        [System.IO.FileAccess]::Read,
        [System.IO.FileShare]::Read
    )
    $reader = $null
    try {
        $reader = [System.IO.BinaryReader]::new($stream)
        if ($reader.ReadUInt16() -ne 0x5A4D) {
            throw "Runtime is not a PE image: $Path"
        }
        $stream.Position = 0x3C
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt $stream.Length - 6) {
            throw "Runtime has an invalid PE header offset: $Path"
        }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) {
            throw "Runtime has an invalid PE signature: $Path"
        }
        return $reader.ReadUInt16()
    } finally {
        if ($null -ne $reader) {
            $reader.Dispose()
        } else {
            $stream.Dispose()
        }
    }
}

$packageRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $packageRoot "..\..")).Path
$lockPath = Join-Path $packageRoot "build-lock.json"
$lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
$resolvedRuntimeDir = Resolve-FullPath $repoRoot $RuntimeDir
$resolvedBuildManifest = Resolve-FullPath $repoRoot $BuildManifestPath
$resolvedSourceRoot = if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    Join-Path $repoRoot "build\sources"
} else {
    Resolve-FullPath $repoRoot $SourceRoot
}
$resolvedOutputDir = if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    Join-Path $repoRoot "dist"
} else {
    Resolve-FullPath $repoRoot $OutputDir
}

$plan = [ordered]@{
    architecture = $Architecture
    version = $Version
    runtimeDir = $resolvedRuntimeDir
    buildManifest = $resolvedBuildManifest
    sourceRoot = $resolvedSourceRoot
    outputDir = $resolvedOutputDir
    requiredConfiguration = @($lock.requiredFfmpegConfiguration)
    requiredEncoders = @($lock.requiredEncoders)
    requiredRuntimeFiles = @($lock.requiredRuntimeFiles)
    installRoot = "%LOCALAPPDATA%\ForPro\RePC\codecs\ffmpeg\$Architecture"
    nsis = "per-user installer"
}
if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 5
    exit 0
}

if (-not (Test-Path -LiteralPath $resolvedBuildManifest)) {
    throw "Build manifest is required: $resolvedBuildManifest"
}
$codecBuild = Get-Content -LiteralPath $resolvedBuildManifest -Raw -Encoding UTF8 |
    ConvertFrom-Json
if ([string]$codecBuild.architecture -ne $Architecture) {
    throw "Build architecture '$($codecBuild.architecture)' does not match '$Architecture'"
}
foreach ($componentName in @("ffmpeg", "x264", "x265")) {
    $manifestProperty = "${componentName}Revision"
    $actualRevision = [string]$codecBuild.$manifestProperty
    $expectedRevision = [string]$lock.components.$componentName.revision
    if ($actualRevision -ne $expectedRevision) {
        throw "$componentName revision '$actualRevision' does not match lock '$expectedRevision'"
    }
}
$configuration = [string]$codecBuild.configuration
foreach ($flag in @($lock.requiredFfmpegConfiguration)) {
    if ($configuration -notmatch [regex]::Escape([string]$flag)) {
        throw "Build manifest is missing required FFmpeg flag: $flag"
    }
}
$encoders = @($codecBuild.encoders | ForEach-Object { [string]$_ })
foreach ($encoder in @($lock.requiredEncoders)) {
    if ([string]$encoder -notin $encoders) {
        throw "Build manifest is missing required encoder: $encoder"
    }
}
$runtimeNames = @($codecBuild.runtimeFiles | ForEach-Object { [string]$_ })
foreach ($runtimeName in $runtimeNames) {
    if ([string]::IsNullOrWhiteSpace($runtimeName) -or
        $runtimeName -ne [System.IO.Path]::GetFileName($runtimeName) -or
        -not $runtimeName.EndsWith(".dll", [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Build manifest contains an unsafe runtime file name: $runtimeName"
    }
}
foreach ($requiredRuntime in @($lock.requiredRuntimeFiles)) {
    if ([string]$requiredRuntime -notin $runtimeNames) {
        throw "Build manifest is missing required runtime: $requiredRuntime"
    }
}
foreach ($runtimeName in $runtimeNames) {
    $runtimePath = Join-Path $resolvedRuntimeDir $runtimeName
    if (-not (Test-Path -LiteralPath $runtimePath)) {
        throw "Runtime file is missing: $runtimeName"
    }
    $expectedMachine = if ($Architecture -eq "arm64") { 0xAA64 } else { 0x8664 }
    $actualMachine = Get-PeMachine $runtimePath
    if ($actualMachine -ne $expectedMachine) {
        throw ("Runtime PE machine 0x{0:X4} does not match {1} (expected 0x{2:X4}): {3}" -f
            $actualMachine, $Architecture, $expectedMachine, $runtimeName)
    }
}

$licenseInputs = [ordered]@{}
foreach ($componentName in @("ffmpeg", "x264", "x265")) {
    $component = $lock.components.$componentName
    $componentRoot = Join-Path $resolvedSourceRoot $componentName
    $actualSourceRevision = (& git -C $componentRoot rev-parse HEAD 2>$null).Trim()
    if ($LASTEXITCODE -ne 0 -or $actualSourceRevision -ne [string]$component.revision) {
        throw "$componentName source does not match build lock: $componentRoot"
    }
    $licenseInput = Join-Path $componentRoot ([string]$component.licenseFile)
    if (-not (Test-Path -LiteralPath $licenseInput)) {
        throw "$componentName license input is missing: $licenseInput"
    }
    $licenseInputs[$componentName] = $licenseInput
}

New-Item -ItemType Directory -Path $resolvedOutputDir -Force | Out-Null
$stageDir = Join-Path $resolvedOutputDir ".codec-pack-$Architecture-$PID"
Assert-SafeChildPath $resolvedOutputDir $stageDir
if (Test-Path -LiteralPath $stageDir) {
    Remove-Item -LiteralPath $stageDir -Recurse -Force
}

try {
    $binDir = Join-Path $stageDir "bin\$Architecture"
    $licensesDir = Join-Path $stageDir "licenses"
    $sourcesDir = Join-Path $stageDir "sources"
    New-Item -ItemType Directory -Path $binDir, $licensesDir, $sourcesDir -Force | Out-Null

    foreach ($runtimeName in $runtimeNames) {
        Copy-Item -LiteralPath (Join-Path $resolvedRuntimeDir $runtimeName) `
            -Destination (Join-Path $binDir $runtimeName) -Force
    }
    Copy-Item -LiteralPath $licenseInputs.ffmpeg `
        -Destination (Join-Path $licensesDir "FFmpeg-COPYING.GPLv2.txt") -Force
    Copy-Item -LiteralPath $licenseInputs.x264 `
        -Destination (Join-Path $licensesDir "x264-COPYING.txt") -Force
    Copy-Item -LiteralPath $licenseInputs.x265 `
        -Destination (Join-Path $licensesDir "x265-COPYING.txt") -Force
    Copy-Item -LiteralPath (Join-Path $packageRoot "THIRD_PARTY_NOTICES.md") `
        -Destination (Join-Path $stageDir "THIRD_PARTY_NOTICES.md") -Force

    $sourceArchive = Join-Path $resolvedOutputDir (
        "RePC-ffmpeg-$Architecture-$Version-source.zip"
    )
    Assert-SafeChildPath $resolvedOutputDir $sourceArchive
    if (Test-Path -LiteralPath $sourceArchive) {
        Remove-Item -LiteralPath $sourceArchive -Force
    }
    $sourceItems = @(
        (Join-Path $resolvedSourceRoot "ffmpeg"),
        (Join-Path $resolvedSourceRoot "x264"),
        (Join-Path $resolvedSourceRoot "x265"),
        $packageRoot
    )
    Compress-Archive -LiteralPath $sourceItems -DestinationPath $sourceArchive `
        -CompressionLevel Optimal
    Copy-Item -LiteralPath $sourceArchive -Destination (
        Join-Path $sourcesDir (Split-Path -Leaf $sourceArchive)
    ) -Force
    Copy-Item -LiteralPath $resolvedBuildManifest `
        -Destination (Join-Path $sourcesDir "repc-ffmpeg-codec-build.json") -Force

    $files = @($runtimeNames | ForEach-Object {
        $path = Join-Path $binDir $_
        [ordered]@{
            name = $_
            bytes = (Get-Item -LiteralPath $path).Length
            sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    })
    $manifest = [ordered]@{
        schema = 1
        product = "RePC FFmpeg codec pack"
        version = $Version
        architecture = $Architecture
        licenseBoundary = "GPL FFmpeg with libx264 and libx265"
        installRoot = "%LOCALAPPDATA%\ForPro\RePC\codecs\ffmpeg\$Architecture"
        ffmpegRevision = [string]$codecBuild.ffmpegRevision
        x264Revision = [string]$codecBuild.x264Revision
        x265Revision = [string]$codecBuild.x265Revision
        configuration = $configuration
        encoders = $encoders
        sourceBundle = Split-Path -Leaf $sourceArchive
        files = $files
    }
    $manifest | ConvertTo-Json -Depth 6 |
        Set-Content -LiteralPath (Join-Path $stageDir "manifest.json") -Encoding UTF8

    $readme = @"
RePC optional FFmpeg x264/x265 codec pack

Architecture: $Architecture
Install path: %LOCALAPPDATA%\ForPro\RePC\codecs\ffmpeg\$Architecture

This GPL codec pack is distributed separately from the RePC base installer.
Separation does not remove FFmpeg, x264, or x265 license obligations. The exact
source archive, license texts, build manifest, notices, and hashes are included.
H.264/HEVC patent licensing may apply separately.
"@
    Set-Content -LiteralPath (Join-Path $stageDir "README.txt") `
        -Value $readme -Encoding UTF8

    $archivePath = Join-Path $resolvedOutputDir "RePC-ffmpeg-$Architecture-$Version.zip"
    Assert-SafeChildPath $resolvedOutputDir $archivePath
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    Compress-Archive -Path (Join-Path $stageDir "*") -DestinationPath $archivePath `
        -CompressionLevel Optimal

    $resolvedNsisCompiler = $NsisCompilerPath
    if ([string]::IsNullOrWhiteSpace($resolvedNsisCompiler)) {
        $makensis = Get-Command makensis.exe -ErrorAction SilentlyContinue
        if ($null -ne $makensis) {
            $resolvedNsisCompiler = $makensis.Source
        }
    }
    $setupPath = Join-Path $resolvedOutputDir (
        "RePC-ffmpeg-$Architecture-$Version-setup.exe"
    )
    $stableSetupPath = Join-Path $resolvedOutputDir "RePC-ffmpeg-$Architecture-setup.exe"
    if (-not [string]::IsNullOrWhiteSpace($resolvedNsisCompiler) -and
        (Test-Path -LiteralPath $resolvedNsisCompiler)) {
        foreach ($path in @($setupPath, $stableSetupPath)) {
            Assert-SafeChildPath $resolvedOutputDir $path
            if (Test-Path -LiteralPath $path) {
                Remove-Item -LiteralPath $path -Force
            }
        }
        & $resolvedNsisCompiler `
            "/DREPC_ARCH=$Architecture" `
            "/DREPC_VERSION=$Version" `
            "/DREPC_STAGE_DIR=$stageDir" `
            "/DREPC_OUT_FILE=$setupPath" `
            (Join-Path $packageRoot "packaging\ffmpeg-codec-pack.nsi")
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $setupPath)) {
            throw "NSIS codec-pack build failed"
        }
        Copy-Item -LiteralPath $setupPath -Destination $stableSetupPath -Force
    } elseif ($RequireNsis) {
        throw "makensis.exe was not found; install NSIS or pass -NsisCompilerPath"
    } else {
        Write-Warning "makensis.exe was not found; ZIP generated, NSIS installer pending"
    }

    $hashInputs = @($archivePath, $sourceArchive)
    foreach ($path in @($setupPath, $stableSetupPath)) {
        if (Test-Path -LiteralPath $path) {
            $hashInputs += $path
        }
    }
    $hashLines = @($hashInputs | ForEach-Object {
        $hash = (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $(Split-Path -Leaf $_)"
    })
    Set-Content -LiteralPath (Join-Path $resolvedOutputDir "SHA256SUMS") `
        -Value $hashLines -Encoding ASCII
    Copy-IfDifferent $resolvedBuildManifest (
        Join-Path $resolvedOutputDir "repc-ffmpeg-codec-build-$Architecture.json"
    )

    Write-Host "Codec pack archive: $archivePath"
    Write-Host "Corresponding source: $sourceArchive"
    if (Test-Path -LiteralPath $setupPath) {
        Write-Host "NSIS installer: $setupPath"
        Write-Host "Stable installer alias: $stableSetupPath"
    }
} finally {
    if (Test-Path -LiteralPath $stageDir) {
        Assert-SafeChildPath $resolvedOutputDir $stageDir
        Remove-Item -LiteralPath $stageDir -Recurse -Force
    }
}
