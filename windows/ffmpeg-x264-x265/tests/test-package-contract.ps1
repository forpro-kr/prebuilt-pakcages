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
Assert-Contains $packageScript "0xAA64"
Assert-Contains $packageScript 'RePC-ffmpeg-$Architecture-setup.exe'
Assert-Contains $packageScript "makensis.exe"
Assert-Contains $buildScript "--enable-gpl"
Assert-Contains $buildScript "--enable-libx264"
Assert-Contains $buildScript "--enable-libx265"
Assert-Contains $buildScript "repc-codec-avcodec-62.dll"
Assert-Contains $buildScript "SLIBNAME_WITH_MAJOR=repc-codec-"
Assert-Contains $buildScript "ffmpeg_namespace_ready"
Assert-Contains $buildScript "llvm-readobj --coff-imports"
Assert-Contains $buildScript "-static-libstdc++"
foreach ($runtimeName in @("libx264-165.dll", "libx265.dll")) {
    if ($runtimeName -notin @($lock.requiredRuntimeFiles)) {
        throw "Missing locked codec runtime: $runtimeName"
    }
}
Assert-Contains $nsis "RequestExecutionLevel user"
Assert-Contains $nsis '$LOCALAPPDATA\ForPro\RePC\codecs\ffmpeg\${REPC_ARCH}'
Assert-Contains $nsis "WriteUninstaller"
Assert-Contains $boundary "GPL runtime"

Write-Output "prebuilt_ffmpeg_codec_pack_contract=ok"
