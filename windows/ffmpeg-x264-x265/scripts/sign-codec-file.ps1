param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$SignToolPath,
    [Parameter(Mandatory = $true)][string]$CertificateThumbprint,
    [string]$TimestampUrl = 'http://timestamp.digicert.com',
    [string]$VerifiedCopyPath = ''
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$env:PSModulePath = (Join-Path $PSHOME 'Modules') + ';' + $env:PSModulePath

function Invoke-CodecFileSigning {
    param([string]$Path, [string]$SignToolPath, [string]$CertificateThumbprint,
        [string]$TimestampUrl = 'http://timestamp.digicert.com', [string]$VerifiedCopyPath = '')
    if ($CertificateThumbprint -notmatch '^[0-9a-fA-F]{40}$') { throw 'Invalid company certificate thumbprint' }
    $uri = [uri]$TimestampUrl
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -notin @('http', 'https') -or $uri.UserInfo -or $uri.Fragment) {
        throw 'Timestamp server must be an absolute HTTP(S) URL without credentials or fragment'
    }
    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $resolvedTool = (Resolve-Path -LiteralPath $SignToolPath).Path
    # The caller owns Global\RePCJenkinsSigning across the compiler and outer
    # installer signing. A compiler callback must never reacquire that mutex.
    & $resolvedTool sign /sha1 $CertificateThumbprint /fd SHA256 /tr $TimestampUrl /td SHA256 $resolvedPath
    if ($LASTEXITCODE -ne 0) { throw 'Codec file signing failed' }
    & $resolvedTool verify /pa /tw $resolvedPath
    if ($LASTEXITCODE -ne 0) { throw 'Codec signature/timestamp verification failed' }
    $signature = Get-AuthenticodeSignature -LiteralPath $resolvedPath
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Thumbprint -ine $CertificateThumbprint -or
        $null -eq $signature.TimeStamperCertificate) {
        throw 'Codec file lacks the pinned valid company signature and timestamp'
    }
    $hash = (Get-FileHash -LiteralPath $resolvedPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $record = [ordered]@{ signatureStatus = [string]$signature.Status;
        signerThumbprint = $signature.SignerCertificate.Thumbprint;
        timestampPresent = $true; sha256 = $hash; bytes = (Get-Item -LiteralPath $resolvedPath).Length }
    if ($VerifiedCopyPath) {
        Copy-Item -LiteralPath $resolvedPath -Destination $VerifiedCopyPath -Force
        if ((Get-FileHash -LiteralPath $VerifiedCopyPath -Algorithm SHA256).Hash -ine $hash) {
            throw 'Verified uninstaller copy differs from the signed compiler input'
        }
        $record | ConvertTo-Json | Set-Content -LiteralPath ($VerifiedCopyPath + '.signing.json') -Encoding UTF8
    }
    return $record
}

Invoke-CodecFileSigning @PSBoundParameters | ConvertTo-Json
