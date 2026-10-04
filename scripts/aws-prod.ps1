<#
.SYNOPSIS
  One helper to create and operate the single "prod" AWS environment from your machine (docs/aws-prod-quickstart.md).
.DESCRIPTION
  Subcommands: check, root-keys-reminder, bootstrap-plan, bootstrap-apply, images, plan, apply, status,
  upload, destroy-plan, destroy.

  Safety properties (asserted by scripts/tests/aws-prod.Tests.ps1):
   - -Profile is mandatory; the profile names default, payana*, higo*, standar*, management* are refused unless
     -AllowAnyProfile is passed.
   - Nothing is ever applied or destroyed without a saved plan file, a printed plan summary and the typed word
     APPLY (or DESTROY). There is no auto-approve and no flag that skips the prompt.
   - The root user is allowed (it is the documented path) but check prints a clear one-time warning with the 3
     safety lines. This script never reads ~/.aws or any credential file; the aws CLI resolves the profile.
   - Secrets are never passed or printed. Account ids appear only on your console and in uncommitted local files.
.EXAMPLE
  ./scripts/aws-prod.ps1 check -Profile pulso-prod
  ./scripts/aws-prod.ps1 bootstrap-plan -Profile pulso-prod
  ./scripts/aws-prod.ps1 upload -Profile pulso-prod -Path D:\data\e0 -Dataset e0
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('check', 'root-keys-reminder', 'bootstrap-plan', 'bootstrap-apply', 'images', 'plan', 'apply',
        'status', 'upload', 'destroy-plan', 'destroy')]
    [string]$Command,
    [string]$Profile = '',
    [switch]$AllowAnyProfile,
    [string]$PulsoDir = '',
    [string]$AgentCoreDir = '',
    [string]$LlmGatewayDir = '',
    [string]$SupportPlatformDir = '',
    [string]$CaddyUpstreamDigest = '',
    [string]$Path = '',
    [string]$Dataset = '',
    [string]$VarFile = '',
    [switch]$DryRun,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

$script:Region = 'us-east-1'
$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:RefusedProfile = '^(default|payana.*|higo.*|standar.*|management.*)$'
$script:RootWarned = $false

function Get-WorkDir {
    $dir = if ($env:AWS_PROD_WORKDIR) { $env:AWS_PROD_WORKDIR } else { Join-Path $script:RepoRoot '.scratch/aws-prod' }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dir
}

function Get-BootstrapDir { Join-Path $script:RepoRoot 'terraform/bootstrap' }
function Get-EnvDir { Join-Path $script:RepoRoot 'terraform/envs/hackathon' }

function Assert-Profile([string]$Name, [bool]$AllowAny) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Pass -Profile <name> (the profile you made with: aws configure --profile pulso-prod).' }
    if (-not $AllowAny -and $Name -imatch $script:RefusedProfile) {
        throw "Refusing profile '$Name': default, payana*, higo*, standar* and management* are not allowed targets. Use a dedicated profile such as pulso-prod, or pass -AllowAnyProfile if you are sure."
    }
}

function Invoke-Aws {
    # Always pins the profile and region; returns stdout lines; throws on a non-zero exit.
    param([string]$AwsProfile, [string[]]$CliArgs)
    $out = & aws @CliArgs --profile $AwsProfile --region $script:Region
    if ($LASTEXITCODE -ne 0) { throw "aws $($CliArgs[0..1] -join ' ') failed (exit $LASTEXITCODE)." }
    $out
}

function Get-Identity([string]$AwsProfile) {
    $json = (Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('sts', 'get-caller-identity', '--output', 'json')) -join "`n"
    $id = $json | ConvertFrom-Json
    $type = if ($id.Arn -match ':root$') { 'root' } elseif ($id.Arn -match ':user/') { 'iam-user' } elseif ($id.Arn -match ':assumed-role/') { 'assumed-role' } else { 'other' }
    [pscustomobject]@{ Account = $id.Account; Arn = $id.Arn; Type = $type }
}

function Show-RootWarning([switch]$Brief) {
    if ($script:RootWarned) { return }
    $script:RootWarned = $true
    if ($Brief) {
        Write-Host 'WARNING: you are the root user (allowed, not blocked). Run "aws-prod.ps1 root-keys-reminder" for the 3 safety lines.'
        return
    }
    Write-Host ''
    Write-Host 'WARNING: you are using the ROOT user. This is allowed, but root is account-wide and no permission boundary applies to it.'
    Write-Host '  1. Enable MFA on root (console > account menu > Security credentials > Multi-factor authentication).'
    Write-Host '  2. Create the root access key only in the console, and enter it only with: aws configure --profile pulso-prod'
    Write-Host '  3. Delete the root access key when you are done (console > Security credentials > Access keys > Deactivate, then Delete).'
    Write-Host ''
}

function Invoke-Preflight([string]$AwsProfile, [bool]$AllowAny) {
    Assert-Profile $AwsProfile $AllowAny
    $env:AWS_PROFILE = $AwsProfile
    $env:AWS_REGION = $script:Region
    $env:AWS_DEFAULT_REGION = $script:Region
    $id = Get-Identity $AwsProfile
    if ($id.Type -eq 'root') { Show-RootWarning -Brief }
    $id
}

function Invoke-Tf {
    param([string]$Dir, [string[]]$TfArgs)
    & terraform "-chdir=$Dir" @TfArgs
    if ($LASTEXITCODE -ne 0) { throw "terraform $($TfArgs[0]) failed (exit $LASTEXITCODE)." }
}

function Read-TypedWord([string]$Word) {
    $answer = Read-Host "Type $Word to continue (anything else aborts)"
    if ($answer -cne $Word) { throw "Aborted: you did not type $Word." }
}

function Show-PlanSummary([string]$Dir, [string]$PlanFile) {
    Write-Host "Saved plan: $PlanFile"
    $text = & terraform "-chdir=$Dir" show -no-color $PlanFile
    if ($LASTEXITCODE -ne 0) { throw 'terraform show failed.' }
    $lines = @($text | Where-Object { $_ -match '^\s*#\s' -or $_ -match '^(Plan:|No changes)' })
    $lines | ForEach-Object { Write-Host $_ }
    if (-not ($lines | Where-Object { $_ -match '^(Plan:|No changes)' })) { Write-Host '(no Plan: line found; read the full plan with terraform show)' }
}

function Assert-SavedPlan([string]$PlanFile, [string]$What) {
    if (-not (Test-Path -LiteralPath $PlanFile)) { throw "No saved plan at $PlanFile. Run the matching plan subcommand first ($What). Nothing is applied without a saved plan." }
}

function Invoke-GuardedApply([string]$Dir, [string]$PlanFile, [string]$Word, [string]$PlanCommand) {
    Assert-SavedPlan $PlanFile $PlanCommand
    Show-PlanSummary $Dir $PlanFile
    Read-TypedWord $Word
    Invoke-Tf $Dir @('apply', '-input=false', $PlanFile)
}

function Get-StateBucket([string]$Account) { "pulso-prod-tfstate-$Account" }

function Write-BackendHcl([string]$Account) {
    $file = Join-Path (Get-WorkDir) 'backend.hcl'
    @"
bucket       = "$(Get-StateBucket $Account)"
key          = "pulso/prod/hackathon/terraform.tfstate"
region       = "$($script:Region)"
use_lockfile = true
encrypt      = true
"@ | Set-Content -Encoding utf8 $file
    $file
}

function Resolve-VarFile([string]$Explicit) {
    $file = if ($Explicit) { $Explicit } else { Join-Path (Get-EnvDir) 'prod.tfvars' }
    if (-not (Test-Path -LiteralPath $file)) { throw "Missing $file. Run: aws-prod.ps1 images (it writes it), or copy prod.tfvars.example and fill the digests." }
    if ((Get-Content -Raw $file) -match 'REPLACE_WITH|<registry>') { throw "$file still has placeholders (REPLACE_WITH_..., <registry>). Run aws-prod.ps1 images, or fill them by hand." }
    $file
}

function Initialize-Env([string]$Account) {
    $backend = Write-BackendHcl $Account
    Invoke-Tf (Get-EnvDir) @('init', '-input=false', '-reconfigure', "-backend-config=$backend")
}

function Set-ImagesInTfvars([string]$File, [hashtable]$Refs) {
    # Rewrites only the images = { ... } block; everything else in the file is preserved.
    $block = @"
images = {
  core = {
    core    = "$($Refs['core'])"
    gateway = "$($Refs['gateway'])"
  }
  platform = {
    support_api = "$($Refs['support_api'])"
    support_web = "$($Refs['support_web'])"
    proxy       = "$($Refs['proxy'])"
  }
  engine = {
    pulso = "$($Refs['pulso'])"
    proxy = "$($Refs['proxy'])"
  }
}
"@
    if (-not (Test-Path -LiteralPath $File)) { Copy-Item (Join-Path (Get-EnvDir) 'prod.tfvars.example') $File }
    $text = Get-Content -Raw $File
    $new = [regex]::Replace($text, '(?ms)^images\s*=\s*\{.*?^\}\s*$', { param($m) $block.TrimEnd() })
    [IO.File]::WriteAllText($File, $new, (New-Object Text.UTF8Encoding($false)))
}

function Invoke-ReleaseImage {
    param([string]$AwsProfile, [string]$Registry, [string]$Repo, [string]$Context, [string]$Image,
          [string]$Dockerfile = '', [string[]]$BuildContext = @())
    $out = Join-Path (Get-WorkDir) "release-$Image"
    $params = @{ Context = $Context; ImageName = $Image; OutDir = $out; Push = $true; AwsProfile = $AwsProfile; EcrRepository = "$Registry/$Repo" }
    if ($Dockerfile) { $params.Dockerfile = $Dockerfile }
    if ($BuildContext.Count) { $params.BuildContext = $BuildContext }
    & (Join-Path $PSScriptRoot 'release-engine.ps1') @params
    $manifest = Get-Content -Raw (Join-Path $out 'deploy-manifest.json') | ConvertFrom-Json
    if (-not $manifest.pushed) { throw "$Image was not pushed." }
    "$Registry/$Repo@$($manifest.image_digest)"
}

function Invoke-MirrorCaddy([string]$AwsProfile, [string]$Registry, [string]$Digest) {
    if ($Digest -notmatch '^sha256:[0-9a-f]{64}$') { throw 'Pass -CaddyUpstreamDigest sha256:<64 hex> (the upstream caddy image digest you chose).' }
    $src = "docker.io/library/caddy@$Digest"
    $dst = "$Registry/prod/caddy:mirror-$($Digest.Substring(7, 12))"
    & docker pull $src; if ($LASTEXITCODE) { throw 'caddy pull failed' }
    & docker tag $src $dst
    (Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ecr', 'get-login-password')) | & docker login --username AWS --password-stdin $Registry | Out-Null
    & docker push $dst; if ($LASTEXITCODE) { throw 'caddy push failed' }
    $repoDigest = (& docker image inspect --format '{{index .RepoDigests 0}}' $dst).Trim()
    if ($repoDigest -notmatch '@(sha256:[0-9a-f]{64})$') { throw 'caddy push produced no registry digest.' }
    "$Registry/prod/caddy@$($Matches[1])"
}

function Invoke-Images($p, $id) {
    foreach ($req in 'PulsoDir', 'AgentCoreDir', 'LlmGatewayDir', 'SupportPlatformDir') {
        if (-not $p[$req] -or -not (Test-Path -LiteralPath $p[$req])) { throw "images needs -$req <existing directory>." }
    }
    $registry = "$($id.Account).dkr.ecr.$($script:Region).amazonaws.com"
    $prof = $p.Profile
    $refs = @{}
    $refs.pulso = Invoke-ReleaseImage $prof $registry 'prod/pulso-engine' $p.PulsoDir 'pulso'
    $refs.core = Invoke-ReleaseImage $prof $registry 'prod/core-runtime' $p.AgentCoreDir 'core-runtime' (Join-Path $p.AgentCoreDir 'Dockerfile') @("core=$($p.AgentCoreDir)")
    $refs.gateway = Invoke-ReleaseImage $prof $registry 'prod/llm-gateway' $p.LlmGatewayDir 'llm-gateway' (Join-Path $p.LlmGatewayDir 'Dockerfile')
    $refs.support_api = Invoke-ReleaseImage $prof $registry 'prod/support-platform-api' (Join-Path $p.SupportPlatformDir 'api') 'support-platform-api'
    $refs.support_web = Invoke-ReleaseImage $prof $registry 'prod/support-platform-web' (Join-Path $p.SupportPlatformDir 'web') 'support-platform-web'
    $refs.proxy = Invoke-MirrorCaddy $prof $registry $p.CaddyUpstreamDigest
    $file = if ($p.VarFile) { $p.VarFile } else { Join-Path (Get-EnvDir) 'prod.tfvars' }
    Set-ImagesInTfvars $file $refs
    Write-Host "Wrote image digests to $file (uncommitted, ignored by Git)."
}

function Invoke-Status($id, [string]$AwsProfile) {
    $rows = Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ec2', 'describe-instances', '--filters', 'Name=tag:Environment,Values=prod',
        '--query', 'Reservations[].Instances[].[InstanceId,State.Name,InstanceType,Tags[?Key==`Name`]|[0].Value]', '--output', 'text')
    $rows | ForEach-Object { Write-Host $_ }
    foreach ($row in $rows) {
        $f = ($row -split '\s+')
        if ($f.Count -ge 2 -and $f[1] -eq 'running') {
            $cmd = (Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ssm', 'send-command', '--instance-ids', $f[0], '--document-name', 'AWS-RunShellScript',
                '--parameters', 'commands=["systemctl is-active pulso-stack","docker ps --format {{.Names}}:{{.Status}}"]', '--query', 'Command.CommandId', '--output', 'text')) -join ''
            Start-Sleep -Seconds 4
            $res = Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ssm', 'get-command-invocation', '--command-id', $cmd, '--instance-id', $f[0], '--query', 'StandardOutputContent', '--output', 'text')
            Write-Host "--- $($f[0]) health ---"
            $res | ForEach-Object { Write-Host $_ }
        }
    }
}

function Invoke-Upload($p, [string]$AwsProfile) {
    if (-not $p.Path -or -not (Test-Path -LiteralPath $p.Path -PathType Container)) { throw 'upload needs -Path <existing directory>.' }
    if ($p.Dataset -notmatch '^[a-z0-9][a-z0-9_-]{0,62}$') { throw 'upload needs -Dataset <name> (lowercase letters, digits, - and _).' }
    $bucket = (& terraform "-chdir=$(Get-EnvDir)" output -raw bucket_name); if ($LASTEXITCODE) { throw 'Cannot read bucket_name; run plan/apply first.' }
    $kms = (& terraform "-chdir=$(Get-EnvDir)" output -raw kms_key_arn); if ($LASTEXITCODE) { throw 'Cannot read kms_key_arn.' }
    $args2 = @('s3', 'sync', $p.Path, "s3://$bucket/landing/$($p.Dataset)/", '--sse', 'aws:kms', '--sse-kms-key-id', $kms)
    if ($p.DryRun) { $args2 += '--dryrun' }
    Invoke-Aws -AwsProfile $AwsProfile -CliArgs $args2 | ForEach-Object { Write-Host $_ }
}

function Invoke-AwsProd {
    [CmdletBinding()]
    param([string]$Command, [string]$Profile, [bool]$AllowAnyProfile = $false, [hashtable]$Options = @{})
    $p = @{} + $Options; $p.Profile = $Profile
    if (-not $Command) { throw 'Usage: aws-prod.ps1 <check|root-keys-reminder|bootstrap-plan|bootstrap-apply|images|plan|apply|status|upload|destroy-plan|destroy> -Profile <name>' }

    if ($Command -eq 'root-keys-reminder') { $script:RootWarned = $false; Show-RootWarning; return }

    if ($Command -eq 'check') {
        Assert-Profile $Profile $AllowAnyProfile
        $env:AWS_PROFILE = $Profile
        $id = Get-Identity $Profile
        Write-Host "Account id : $($id.Account)"
        Write-Host "Caller ARN : $($id.Arn)"
        Write-Host "ARN type   : $($id.Type)"
        if ($id.Type -eq 'root') { Show-RootWarning }
        Write-Host 'Compare the account id with the console by eye before any apply.'
        return
    }

    $id = Invoke-Preflight $Profile $AllowAnyProfile
    $work = Get-WorkDir
    switch ($Command) {
        'bootstrap-plan' {
            Invoke-Tf (Get-BootstrapDir) @('init', '-input=false')
            Invoke-Tf (Get-BootstrapDir) @('plan', '-input=false', "-out=$(Join-Path $work 'bootstrap.tfplan')")
            Show-PlanSummary (Get-BootstrapDir) (Join-Path $work 'bootstrap.tfplan')
        }
        'bootstrap-apply' {
            Invoke-GuardedApply (Get-BootstrapDir) (Join-Path $work 'bootstrap.tfplan') 'APPLY' 'bootstrap-plan'
            Write-Host "State bucket: $(Get-StateBucket $id.Account). The bootstrap state itself stays local in terraform/bootstrap (back it up)."
        }
        'images' { Invoke-Images $p $id }
        'plan' {
            $vf = Resolve-VarFile $p.VarFile
            Initialize-Env $id.Account
            Invoke-Tf (Get-EnvDir) @('plan', '-input=false', "-var-file=$vf", "-out=$(Join-Path $work 'prod.tfplan')")
            Show-PlanSummary (Get-EnvDir) (Join-Path $work 'prod.tfplan')
        }
        'apply' {
            Initialize-Env $id.Account
            Invoke-GuardedApply (Get-EnvDir) (Join-Path $work 'prod.tfplan') 'APPLY' 'plan'
        }
        'status' { Invoke-Status $id $Profile }
        'upload' { Initialize-Env $id.Account; Invoke-Upload $p $Profile }
        'destroy-plan' {
            $vf = Resolve-VarFile $p.VarFile
            Initialize-Env $id.Account
            Invoke-Tf (Get-EnvDir) @('plan', '-destroy', '-input=false', "-var-file=$vf", "-out=$(Join-Path $work 'destroy.tfplan')")
            Show-PlanSummary (Get-EnvDir) (Join-Path $work 'destroy.tfplan')
            Write-Host 'Data protections (protect_data_volume, RDS deletion protection) may block parts of this plan on purpose; see docs/operations.md teardown.'
        }
        'destroy' {
            Initialize-Env $id.Account
            Invoke-GuardedApply (Get-EnvDir) (Join-Path $work 'destroy.tfplan') 'DESTROY' 'destroy-plan'
        }
    }
}

if ($LibraryOnly) { return }

$options = @{
    PulsoDir = $PulsoDir; AgentCoreDir = $AgentCoreDir; LlmGatewayDir = $LlmGatewayDir; SupportPlatformDir = $SupportPlatformDir
    CaddyUpstreamDigest = $CaddyUpstreamDigest; Path = $Path; Dataset = $Dataset; VarFile = $VarFile; DryRun = [bool]$DryRun
}
Invoke-AwsProd -Command $Command -Profile $Profile -AllowAnyProfile ([bool]$AllowAnyProfile) -Options $options
