param([string]$NsisCompilerPath = 'C:\msys64\ucrt64\bin\makensis.exe')
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
    throw "AirDesk package must stay on libavcodec major 62 until its delay-import ABI changes"
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
Assert-Contains $packageScript 'AirDesk-ffmpeg-$Architecture-setup.exe'
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
Assert-Contains $nsis '$PROGRAMFILES64\AirDesk\codecs\ffmpeg\${REPC_ARCH}\${REPC_VERSION}'
Assert-Contains $nsis 'Software\AirDesk\FFmpegCodecPack\${REPC_ARCH}'
Assert-Contains $nsis 'Uninstall\AirDeskFFmpegCodecPack-${REPC_ARCH}-${REPC_VERSION}'
Assert-Contains $nsis '"Publisher" "AirDesk"'
Assert-Contains $packageScript 'product = "AirDesk FFmpeg codec pack"'
Assert-Contains $packageScript 'https://api.airdesk.co.kr/'
Assert-Contains $packageScript 'AirDesk-ffmpeg-codec-build-$Architecture.json'
foreach ($retired in @('Software\ForPro\RePC', '$PROGRAMFILES64\ForPro', 'forpro-remote')) {
    if ($nsis.Contains($retired)) { throw "New installer still writes legacy branding/path: $retired" }
}
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
    [string]$packagePlan.installRoot -ne "%ProgramW6432%\AirDesk\codecs\ffmpeg\x64\$($lock.version)") {
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

$armPlanOutput = & $powershellCli -NoProfile -File $packagePath -Architecture arm64 `
    -RuntimeDir 'build\version-contract\runtime' `
    -BuildManifestPath 'build\version-contract\runtime\repc-ffmpeg-codec-build.json' -PlanOnly
if ($LASTEXITCODE -ne 0 -or [string](($armPlanOutput | ConvertFrom-Json).installRoot) -ne
    "%ProgramW6432%\AirDesk\codecs\ffmpeg\arm64\$($lock.version)") {
    throw 'ARM64 package plan did not use the canonical AirDesk path'
}

if (Test-Path -LiteralPath $NsisCompilerPath) {
    # These executables contain dummy data, never real codec payloads. They
    # validate both NSIS architecture/ownership branches without installing.
    $fixtureRoot = Join-Path $packageRoot ('..\..\build\airdesk-codec-nsis-fixture-' + [guid]::NewGuid().ToString('N'))
    $fixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
    $stage = Join-Path $fixtureRoot 'COMPILE-ONLY-stage'
    foreach ($arch in @('x64', 'arm64')) {
        $bin = Join-Path $stage "bin\$arch"
        New-Item -ItemType Directory -Path $bin, (Join-Path $stage 'licenses'), (Join-Path $stage 'sources') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $bin 'repc-codec-avcodec-62.dll') -Value 'SYNTHETIC COMPILE ONLY; NOT A DLL' -Encoding ASCII
        foreach ($file in @('README.txt', 'THIRD_PARTY_NOTICES.md', 'licenses\FFmpeg-COPYING.GPLv2.txt', 'sources\SOURCE.txt')) {
            Set-Content -LiteralPath (Join-Path $stage $file) -Value 'SYNTHETIC COMPILE ONLY; DO NOT INSTALL OR DISTRIBUTE' -Encoding ASCII
        }
        @{ schema = 1; architecture = $arch; version = [string]$lock.version; syntheticCompileOnly = $true } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stage 'manifest.json') -Encoding UTF8
        $fixtureExe = Join-Path $fixtureRoot "AirDesk-ffmpeg-$arch-$($lock.version)-COMPILE-ONLY.exe"
        & $NsisCompilerPath '-V2' '-INPUTCHARSET' 'UTF8' "-DREPC_ARCH=$arch" "-DREPC_VERSION=$($lock.version)" `
            "-DREPC_STAGE_DIR=$stage" "-DREPC_OUT_FILE=$fixtureExe" (Join-Path $packageRoot 'packaging\ffmpeg-codec-pack.nsi')
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $fixtureExe)) { throw "Synthetic NSIS compile failed: $arch" }
    }
    Write-Output "airdesk_codec_nsis_compile_only=ok artifacts=$fixtureRoot"
} else {
    Write-Output 'airdesk_codec_nsis_compile_only=not-run (makensis unavailable)'
}

Write-Output "prebuilt_ffmpeg_codec_pack_contract=ok"
