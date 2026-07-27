param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("x64", "arm64")]
    [string]$Architecture,
    [string]$Msys2Root = "C:\msys64",
    [string]$SourceRoot = "",
    [string]$BuildRoot = "",
    [int]$Parallel = 0,
    [switch]$Clean,
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

function Convert-ToMsysPath {
    param([string]$BashPath, [string]$WindowsPath)
    $result = & $BashPath -lc "cygpath -u '$($WindowsPath.Replace("'", "'\''"))'"
    if ($LASTEXITCODE -ne 0) {
        throw "cygpath failed for $WindowsPath"
    }
    return ([string]$result).Trim()
}

$packageRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot "..")).Path
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $packageRoot "..\..")).Path
$bashPath = Join-Path $Msys2Root "usr\bin\bash.exe"
if (-not (Test-Path -LiteralPath $bashPath)) {
    throw "MSYS2 bash not found: $bashPath"
}
$resolvedSourceRoot = if ([string]::IsNullOrWhiteSpace($SourceRoot)) {
    Join-Path $repoRoot "build\sources"
} else {
    Resolve-FullPath $repoRoot $SourceRoot
}
$resolvedBuildRoot = if ([string]::IsNullOrWhiteSpace($BuildRoot)) {
    Join-Path $repoRoot "build\windows-codecs\$Architecture"
} else {
    Resolve-FullPath $repoRoot $BuildRoot
}
if ($Parallel -le 0) {
    $Parallel = [Environment]::ProcessorCount
}

$msystem = if ($Architecture -eq "arm64") { "CLANGARM64" } else { "UCRT64" }
$msysPrefix = if ($Architecture -eq "arm64") { "/clangarm64" } else { "/ucrt64" }
$sourceMsys = Convert-ToMsysPath $bashPath $resolvedSourceRoot
$buildMsys = Convert-ToMsysPath $bashPath $resolvedBuildRoot
$scriptMsys = Convert-ToMsysPath $bashPath (
    Join-Path $PSScriptRoot "build-windows-codecs.sh"
)
$lockMsys = Convert-ToMsysPath $bashPath (Join-Path $packageRoot "build-lock.json")

$plan = [ordered]@{
    architecture = $Architecture
    msystem = $msystem
    msys2Root = [System.IO.Path]::GetFullPath($Msys2Root)
    sourceRoot = $resolvedSourceRoot
    buildRoot = $resolvedBuildRoot
    parallel = $Parallel
    clean = [bool]$Clean
    output = Join-Path $resolvedBuildRoot "runtime"
    manifest = Join-Path $resolvedBuildRoot "runtime\repc-ffmpeg-codec-build.json"
}
if ($PlanOnly) {
    $plan | ConvertTo-Json -Depth 4
    exit 0
}

foreach ($sourceName in @("ffmpeg", "x264", "x265")) {
    if (-not (Test-Path -LiteralPath (Join-Path $resolvedSourceRoot "$sourceName\.git"))) {
        throw "Pinned source is missing for $sourceName; run fetch-sources.ps1 first"
    }
}

$previousMsystem = $env:MSYSTEM
$previousChereInvoking = $env:CHERE_INVOKING
try {
    $env:MSYSTEM = $msystem
    $env:CHERE_INVOKING = "1"
    $cleanValue = if ($Clean) { "1" } else { "0" }
    $scriptArguments = @(
        "'$scriptMsys'",
        "'$Architecture'",
        "'$sourceMsys'",
        "'$buildMsys'",
        "'$lockMsys'",
        "'$Parallel'",
        "'$cleanValue'"
    ) -join " "
    $command = 'export PATH="' + $msysPrefix + '/bin:/usr/bin:$PATH"; ' +
        $scriptArguments
    & $bashPath -lc $command
    if ($LASTEXITCODE -ne 0) {
        throw "Windows codec build failed with exit code $LASTEXITCODE"
    }
} finally {
    $env:MSYSTEM = $previousMsystem
    $env:CHERE_INVOKING = $previousChereInvoking
}

Write-Host "Codec runtime: $(Join-Path $resolvedBuildRoot 'runtime')"
