<#
.SYNOPSIS
  Local, offline-by-default release of the Pulso engine image (TA1).
.DESCRIPTION
  Builds the image from -Dockerfile, resolves its sha256 DIGEST, tags it by digest (never by a moving tag), produces an
  SBOM with syft and an audit with cargo-audit/trivy when present (otherwise records an explicit skip, never fakes a
  result) and writes a deploy manifest JSON. Pushes to ECR ONLY with -Push AND an explicit -AwsProfile chosen by a
  human; the default is to refuse. This script never reads ~/.aws/credentials itself and never creates cloud resources.
.EXAMPLE
  ./scripts/release-engine.ps1 -Context D:\path\to\engine -OutDir out\release            # local build, no network push
  ./scripts/release-engine.ps1 -Context ... -Push -AwsProfile <new-profile> -EcrRepository <acct>.dkr.ecr.<region>.amazonaws.com/<repo>
#>
[CmdletBinding()]
param(
    [string]$Context = '.',
    [string]$Dockerfile = (Join-Path (Split-Path $PSScriptRoot -Parent) 'docker/pulso.Dockerfile'),
    [string]$ImageName = 'pulso',
    [string]$OutDir = 'release-out',
    [ValidateSet('docker', 'podman')][string]$Engine = 'docker',
    [switch]$Push,
    [string]$AwsProfile = '',
    [string]$EcrRepository = '',
    [string[]]$BuildContext = @(),   # extra named build contexts, name=path, passed as --build-context
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

function Assert-Digest([string]$Digest) {
    if ($Digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "A sha256 digest is required, got '$Digest'." }
    $Digest
}

function Assert-PushProfile([string]$AwsProfile) {
    if ([string]::IsNullOrWhiteSpace($AwsProfile)) { throw 'Refusing to push: pass -AwsProfile <the profile you created for the new account>.' }
    if ($AwsProfile -eq 'default') { throw "Refusing to push: profile 'default' is not an allowed target; use the dedicated new-account profile." }
}

function Assert-PushAllowed([bool]$Push, [string]$AwsProfile, [string]$Digest) {
    if (-not $Push) { return }
    Assert-PushProfile $AwsProfile
    Assert-Digest $Digest | Out-Null
}

function New-DeployManifest([string]$ImageDigest, [string]$GitSha, [string]$SbomSha256, [bool]$Pushed,
                            [string]$SbomSkipReason = '', [string]$AuditStatus = 'skipped', [string]$AuditNote = '') {
    Assert-Digest $ImageDigest | Out-Null
    if ([string]::IsNullOrEmpty($SbomSha256) -and [string]::IsNullOrEmpty($SbomSkipReason)) {
        throw 'sbom: provide a hash or an explicit skip reason; an SBOM is never faked.'
    }
    [ordered]@{
        schema        = 'pulso-engine-release/1'
        image_digest  = $ImageDigest
        git_sha       = $GitSha
        sbom_sha256   = $SbomSha256
        sbom_skipped  = $SbomSkipReason
        audit_status  = $AuditStatus
        audit_note    = $AuditNote
        pushed        = $Pushed
        created_utc   = (Get-Date).ToUniversalTime().ToString('o')
    }
}

if ($LibraryOnly) { return }

# --- main -----------------------------------------------------------------------------------------------------
if ($Push) { Assert-PushProfile $AwsProfile }
if ($Push -and [string]::IsNullOrWhiteSpace($EcrRepository)) { throw 'Refusing to push: pass -EcrRepository.' }

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$gitSha = (git -C $Context rev-parse HEAD).Trim()
$localTag = "${ImageName}:build-$($gitSha.Substring(0, 12))"
$buildArgs = @(); foreach ($bc in $BuildContext) { $buildArgs += @('--build-context', $bc) }
& $Engine build -f $Dockerfile @buildArgs -t $localTag $Context
if ($LASTEXITCODE) { throw 'build failed' }
$digest = Assert-Digest ((& $Engine image inspect --format '{{.Id}}' $localTag).Trim())
$digestTag = "${ImageName}:" + $digest.Replace(':', '-').Substring(0, 19)
& $Engine tag $localTag $digestTag

$sbomHash = ''; $sbomSkip = ''
if (Get-Command syft -ErrorAction SilentlyContinue) {
    $sbomPath = Join-Path $OutDir 'sbom.spdx.json'
    syft $localTag -o spdx-json=$sbomPath
    if ($LASTEXITCODE) { throw 'syft failed' }
    $sbomHash = (Get-FileHash $sbomPath -Algorithm SHA256).Hash.ToLower()
} else { $sbomSkip = 'syft not installed' }

$auditStatus = 'skipped'; $auditNote = 'neither trivy nor cargo-audit installed'
if (Get-Command trivy -ErrorAction SilentlyContinue) {
    trivy image --exit-code 0 --format json --output (Join-Path $OutDir 'audit-trivy.json') $localTag
    $auditStatus = 'trivy-ran'; $auditNote = 'report in audit-trivy.json; review before deploy'
} elseif (Get-Command cargo-audit -ErrorAction SilentlyContinue) {
    Push-Location $Context; try { cargo audit --json > (Join-Path (Resolve-Path $OutDir) 'audit-cargo.json') } finally { Pop-Location }
    $auditStatus = 'cargo-audit-ran'; $auditNote = 'report in audit-cargo.json; review before deploy'
}

$pushed = $false
if ($Push) {
    Assert-PushAllowed -Push:$true -AwsProfile $AwsProfile -Digest $digest
    $env:AWS_PROFILE = $AwsProfile
    $registry = $EcrRepository.Split('/')[0]
    (aws ecr get-login-password --profile $AwsProfile) | & $Engine login --username AWS --password-stdin $registry
    & $Engine tag $localTag "${EcrRepository}:$($digest.Replace(':', '-').Substring(0, 19))"
    & $Engine push "${EcrRepository}:$($digest.Replace(':', '-').Substring(0, 19))"
    if ($LASTEXITCODE) { throw 'push failed' }
    # The registry digest is what deployments pin; refuse if the engine did not report one.
    $repoDigest = (& $Engine image inspect --format '{{index .RepoDigests 0}}' $localTag).Trim()
    if ($repoDigest -notmatch '@(sha256:[0-9a-f]{64})$') { throw 'push produced no registry digest; refusing to write a manifest.' }
    $digest = $Matches[1]
    $pushed = $true
}

$manifest = New-DeployManifest -ImageDigest $digest -GitSha $gitSha -SbomSha256 $sbomHash -Pushed $pushed `
    -SbomSkipReason $sbomSkip -AuditStatus $auditStatus -AuditNote $auditNote
$manifest | ConvertTo-Json | Set-Content -Encoding utf8 (Join-Path $OutDir 'deploy-manifest.json')
Write-Host "image digest: $digest (pushed=$pushed)"
