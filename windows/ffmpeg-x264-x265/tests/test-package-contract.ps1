$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$packageRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path

function Read-PackageFile {
    param([string]$RelativePath)
    $path = Join-Path $packageRoot $RelativePath
    if (-not (Test-Path -LiteralPath $path)) {
        throw "Missing package file: $RelativePath"
    }
    return Get-Content -LiteralPath $path -Raw -Encoding UTF8
}

function Assert-Contains {
    param([string]$Text, [string]$Needle)
    if (-not $Text.Contains($Needle)) {
        throw "Missing package contract: $Needle"
    }
}

$lock = Get-Content -LiteralPath (Join-Path $packageRoot "build-lock.json") `
    -Raw -Encoding UTF8 | ConvertFrom-Json
if ([int]$lock.components.ffmpeg.expectedLibavcodecMajor -ne 62) {
    throw "RePC package must stay on libavcodec major 62 until its delay-import ABI changes"
}
foreach ($flag in @("--enable-gpl", "--enable-shared", "--enable-libx264", "--enable-libx265")) {
    if ($flag -notin @($lock.requiredFfmpegConfiguration)) {
        throw "Missing locked FFmpeg flag: $flag"
    }
}

$packageScript = Read-PackageFile "scripts\package-codec-pack.ps1"
$buildScript = Read-PackageFile "scripts\build-windows-codecs.sh"
$nsis = Read-PackageFile "packaging\ffmpeg-codec-pack.nsi"
$boundary = Read-PackageFile "..\..\LICENSE_BOUNDARY.md"
Assert-Contains $packageScript "FFmpeg-COPYING.GPLv2.txt"
Assert-Contains $packageScript "x264-COPYING.txt"
Assert-Contains $packageScript "x265-COPYING.txt"
Assert-Contains $packageScript "Get-FileHash"
Assert-Contains $packageScript "Get-PeMachine"
Assert-Contains $packageScript "build-lock.json version"
Assert-Contains $packageScript "packageVersion"
Assert-Contains $packageScript "0xAA64"
Assert-Contains $packageScript 'RePC-ffmpeg-$Architecture-setup.exe'
Assert-Contains $packageScript "makensis.exe"
Assert-Contains $buildScript "--enable-gpl"
Assert-Contains $buildScript "--enable-libx264"
Assert-Contains $buildScript "--enable-libx265"
Assert-Contains $buildScript "repc-codec-avcodec-62.dll"
Assert-Contains $buildScript "SLIBNAME_WITH_MAJOR=repc-codec-"
Assert-Contains $buildScript "ffmpeg_namespace_ready"
Assert-Contains $buildScript '"packageVersion": "$package_version"'
Assert-Contains $buildScript "repc-continuous-bitrate-patch.sha256"
Assert-Contains $buildScript "continuousBitratePatchSha256"
Assert-Contains $packageScript "continuousBitratePatchSha256"
Assert-Contains $buildScript "0003-continuous-bitrate.patch"
Assert-Contains $buildScript "0004-qsv-continuous-bitrate.patch"
Assert-Contains $buildScript "0005-mf-vbr-peak.patch"
Assert-Contains $buildScript "repc-qsv-continuous-bitrate-patch.sha256"
Assert-Contains $buildScript "qsvContinuousBitratePatchSha256"
Assert-Contains $packageScript "qsvContinuousBitratePatchSha256"
Assert-Contains $buildScript 'objdump -p'
Assert-Contains $buildScript "-static-libstdc++"
foreach ($runtimeName in @("libx264-165.dll", "libx265.dll")) {
    if ($runtimeName -notin @($lock.requiredRuntimeFiles)) {
        throw "Missing locked codec runtime: $runtimeName"
    }
}
Assert-Contains $nsis "RequestExecutionLevel admin"
Assert-Contains $nsis '$PROGRAMFILES64\ForPro\RePC\codecs\ffmpeg\${REPC_ARCH}\${REPC_VERSION}'
Assert-Contains $nsis 'SetRegView 64'
Assert-Contains $nsis 'QuietUninstallString'
Assert-Contains $nsis 'SetOverwrite off'
Assert-Contains $nsis 'IfErrors failed'
Assert-Contains $nsis '${IsNativeAMD64}'
Assert-Contains $nsis '${IsNativeARM64}'
Assert-Contains $packageScript 'CertificateThumbprint'
foreach ($encoder in @('h264_nvenc', 'hevc_nvenc', 'h264_qsv', 'hevc_qsv', 'av1_qsv', 'h264_amf', 'hevc_amf')) {
    Assert-Contains $buildScript $encoder
    Assert-Contains $packageScript $encoder
}
Assert-Contains $nsis "WriteUninstaller"
Assert-Contains $boundary "GPL runtime"

# Exercise the read-only plans so a hard-coded CI/package default cannot drift
# from the committed package version. A mismatched legacy override must fail.
if ([string]$lock.version -notmatch '^\d{1,5}\.\d{1,5}\.\d{1,5}$') {
    throw 'Missing committed package version in build-lock.json'
}
$powershellCli = Join-Path $PSHOME 'pwsh.exe'
$packagePath = Join-Path $packageRoot 'scripts\package-codec-pack.ps1'
$packagePlanArgs = @('-NoProfile', '-File', $packagePath, '-Architecture', 'x64',
    '-RuntimeDir', 'build\version-contract\runtime',
    '-BuildManifestPath', 'build\version-contract\runtime\repc-ffmpeg-codec-build.json', '-PlanOnly')
$planOutput = & $powershellCli @packagePlanArgs
if ($LASTEXITCODE -ne 0) { throw 'Default package-version plan failed' }
$packagePlan = $planOutput | ConvertFrom-Json
if ([string]$packagePlan.version -ne [string]$lock.version -or
    -not ([string]$packagePlan.installRoot).EndsWith("\$($lock.version)")) {
    throw 'Package version/install path did not follow the committed lock'
}
$otherVersion = if ([string]$lock.version -eq '0.0.0') { '0.0.1' } else { '0.0.0' }
$rejectedOutput = & $powershellCli @packagePlanArgs -Version $otherVersion 2>&1
if ($LASTEXITCODE -eq 0 -or ($rejectedOutput -join "`n") -notmatch 'Version override') {
    throw 'A package version override differing from the committed lock was accepted'
}
$temporaryManifest = [System.IO.Path]::GetTempFileName()
try {
    foreach ($manifestVersion in @('', $otherVersion)) {
        $staleManifest = @{ schema = 1; architecture = 'x64' }
        if ($manifestVersion) { $staleManifest.packageVersion = $manifestVersion }
        $staleManifest | ConvertTo-Json | Set-Content -LiteralPath $temporaryManifest -Encoding utf8
        $rejectedManifestOutput = & $powershellCli -NoProfile -File $packagePath -Architecture x64 `
            -RuntimeDir 'build\version-contract\runtime' -BuildManifestPath $temporaryManifest 2>&1
        if ($LASTEXITCODE -eq 0 -or ($rejectedManifestOutput -join "`n") -notmatch 'packageVersion') {
            throw 'A missing or stale build-manifest version was accepted'
        }
    }
} finally {
    Remove-Item -LiteralPath $temporaryManifest -Force
}
$buildPlanOutput = & $powershellCli -NoProfile -File (Join-Path $packageRoot 'scripts\build-windows-codecs.ps1') `
    -Architecture x64 -PlanOnly
if ($LASTEXITCODE -ne 0 -or [string](($buildPlanOutput | ConvertFrom-Json).version) -ne [string]$lock.version) {
    throw 'Build plan did not follow the committed package version'
}

Write-Output "prebuilt_ffmpeg_codec_pack_contract=ok"
