param([string]$NsisCompilerPath = 'C:\msys64\ucrt64\bin\makensis.exe')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + ';' + $env:PSModulePath
$packageRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root = Join-Path $packageRoot ('..\..\build\signing-contract-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
    (Join-Path $packageRoot 'scripts\sign-codec-file.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw 'Signing helper did not parse' }
foreach ($function in $ast.FindAll({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    . ([scriptblock]::Create($function.Extent.Text))
}
function Require-Failure([scriptblock]$Action, [string]$Message) {
    try { & $Action | Out-Null } catch {
        if ($_.Exception.Message -notmatch $Message) { throw }
        return
    }
    throw "Expected signing failure missing: $Message"
}
$fakeTool = Join-Path $root 'fake signer.cmd'
@'
@echo off
echo %1>>"%AIRDESK_SIGN_CONTRACT_LOG%"
if "%1"=="sign" exit /b %AIRDESK_SIGN_CONTRACT_SIGN_EXIT%
if "%1"=="verify" exit /b %AIRDESK_SIGN_CONTRACT_VERIFY_EXIT%
exit /b 30
'@ | Set-Content -LiteralPath $fakeTool -Encoding ASCII
$inertInput = Join-Path $root 'inert input.tmp'
[IO.File]::WriteAllBytes($inertInput, [byte[]]@(77,90,0,0))
$copy = Join-Path $root 'inert verified copy.exe'
$thumb = 'a' * 40
$script:signatureStatus = 'Valid'; $script:signatureThumb = $thumb
$script:signatureTimestamp = [pscustomobject]@{}
function Get-AuthenticodeSignature {
    param([string]$LiteralPath)
    [pscustomobject]@{ Status = $script:signatureStatus;
        SignerCertificate = [pscustomobject]@{ Thumbprint = $script:signatureThumb };
        TimeStamperCertificate = $script:signatureTimestamp }
}
$names = @('AIRDESK_SIGN_CONTRACT_LOG', 'AIRDESK_SIGN_CONTRACT_SIGN_EXIT', 'AIRDESK_SIGN_CONTRACT_VERIFY_EXIT', 'AIRDESK_NSIS_CALLBACK_EXIT')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
try {
    $env:AIRDESK_SIGN_CONTRACT_LOG = Join-Path $root 'calls.txt'
    $env:AIRDESK_SIGN_CONTRACT_SIGN_EXIT = '0'; $env:AIRDESK_SIGN_CONTRACT_VERIFY_EXIT = '0'
    $record = Invoke-CodecFileSigning $inertInput $fakeTool $thumb 'http://timestamp.example.invalid' $copy
    if (-not $record.timestampPresent -or -not (Test-Path -LiteralPath ($copy + '.signing.json')) -or
        (Get-FileHash -LiteralPath $copy).Hash -ne (Get-FileHash -LiteralPath $inertInput).Hash) { throw 'Verified copy/receipt missing' }
    $env:AIRDESK_SIGN_CONTRACT_SIGN_EXIT = '7'
    Require-Failure { Invoke-CodecFileSigning $inertInput $fakeTool $thumb 'http://timestamp.example.invalid' } 'signing failed'
    $env:AIRDESK_SIGN_CONTRACT_SIGN_EXIT = '0'; $env:AIRDESK_SIGN_CONTRACT_VERIFY_EXIT = '9'
    Require-Failure { Invoke-CodecFileSigning $inertInput $fakeTool $thumb 'http://timestamp.example.invalid' } 'verification failed'
    $env:AIRDESK_SIGN_CONTRACT_VERIFY_EXIT = '0'; $script:signatureStatus = 'NotTrusted'
    Require-Failure { Invoke-CodecFileSigning $inertInput $fakeTool $thumb 'http://timestamp.example.invalid' } 'pinned valid'
    $script:signatureStatus = 'Valid'; $script:signatureThumb = 'b' * 40
    Require-Failure { Invoke-CodecFileSigning $inertInput $fakeTool $thumb 'http://timestamp.example.invalid' } 'pinned valid'
    $script:signatureThumb = $thumb; $script:signatureTimestamp = $null
    Require-Failure { Invoke-CodecFileSigning $inertInput $fakeTool $thumb 'http://timestamp.example.invalid' } 'pinned valid'
    Require-Failure { Invoke-CodecFileSigning $inertInput $fakeTool 'invalid' 'http://timestamp.example.invalid' } 'thumbprint'
    Require-Failure { Invoke-CodecFileSigning $inertInput $fakeTool $thumb 'http://fixture-user@example.invalid' } 'without credentials'

    # This callback only observes/copies NSIS's temporary uninstaller. Neither
    # executable is installed or run, and no real certificate/token is used.
    $callback = Join-Path $root 'observe callback.ps1'
    @'
param($Path, $SignToolPath, $CertificateThumbprint, $TimestampUrl, $VerifiedCopyPath)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Path)) { exit 31 }
$bytes = [IO.File]::ReadAllBytes($Path)
if ($bytes[0] -ne 77 -or $bytes[1] -ne 90) { exit 32 }
if ([int]$env:AIRDESK_NSIS_CALLBACK_EXIT) { exit ([int]$env:AIRDESK_NSIS_CALLBACK_EXIT) }
Copy-Item -LiteralPath $Path -Destination $VerifiedCopyPath -Force
exit 0
'@ | Set-Content -LiteralPath $callback -Encoding UTF8
    $stage = Join-Path $root 'stage'
    New-Item -ItemType Directory -Path (Join-Path $stage 'bin\x64'), (Join-Path $stage 'bin\arm64'),
        (Join-Path $stage 'licenses'), (Join-Path $stage 'sources') -Force | Out-Null
    foreach ($name in @('README.txt','THIRD_PARTY_NOTICES.md','manifest.json','licenses\FFmpeg-COPYING.GPLv2.txt','sources\SOURCE.txt','bin\x64\dummy.dll','bin\arm64\dummy.dll')) {
        Set-Content -LiteralPath (Join-Path $stage $name) -Value 'INERT COMPILE FIXTURE ONLY' -Encoding ASCII
    }
    $shell = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' })
    foreach ($case in @(@('x64',0), @('arm64',0), @('x64',7), @('x64',9))) {
        $arch = $case[0]; $exitCode = $case[1]
        $env:AIRDESK_NSIS_CALLBACK_EXIT = [string]$exitCode
        $output = Join-Path $root "COMPILE-ONLY-$arch-$exitCode.exe"
        $observed = Join-Path $root "UNINSTALL-COMPILE-ONLY-$arch-$exitCode.exe"
        $arguments = @('-V1','-INPUTCHARSET','UTF8',"-DREPC_ARCH=$arch",'-DREPC_VERSION=0.1.2',
            "-DREPC_STAGE_DIR=$stage","-DREPC_OUT_FILE=$output","-DREPC_SIGN_CALLBACK=$callback",
            "-DREPC_SIGN_POWERSHELL=$shell","-DREPC_SIGN_TOOL=$fakeTool","-DREPC_SIGN_THUMBPRINT=$thumb",
            '-DREPC_SIGN_TIMESTAMP=http://timestamp.example.invalid',"-DREPC_SIGNED_UNINSTALLER=$observed")
        $oldPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $compileOutput = (& $NsisCompilerPath @arguments (Join-Path $packageRoot 'packaging\ffmpeg-codec-pack.nsi') 2>&1 | Out-String)
            $result = $LASTEXITCODE
        } finally { $ErrorActionPreference = $oldPreference }
        if ($exitCode -eq 0) {
            if ($result -ne 0 -or -not (Test-Path -LiteralPath $output) -or -not (Test-Path -LiteralPath $observed)) { throw "Callback compile failed: $compileOutput" }
        } elseif ($result -eq 0) { throw 'Compiler accepted a failed uninstaller sign/verify callback' }
    }
} finally {
    foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
}
Write-Output "codec_signing_contract=ok artifacts=$root"
