<#
.SYNOPSIS
  One helper to create and operate the single "prod" AWS environment from your machine (docs/aws-prod-quickstart.md).
.DESCRIPTION
  Subcommands: check, root-keys-reminder, bootstrap-plan, bootstrap-apply, images, plan, apply, status,
  upload, destroy-plan, destroy, deploy, set-secret, seed-secret-keys.

  seed-secret-keys merges the values Terraform generated (sensitive output generated_secrets: gateway tokens, Ed25519 keys, Core key
  documents) into the EXISTING secret. Merge only: a key that is missing or still CHANGE_ME is added; every key that already holds a
  value (DB passwords, TOTP key, session secret) is kept. Only key names are printed; typed word SEED. Never use
  terraform apply -replace on the secret version: it resets every out-of-band key to CHANGE_ME.

  set-secret -SecretKey <SERVICE>__<VAR> sets one key of the single Secrets Manager secret pulso-prod/hackathon from a
  secure prompt (no echo). The value is never a parameter, never printed or logged, never read from a file, and never
  written inside the repository (only a short-lived temp file outside it, deleted at once). Every other key is kept.

  images -Service <name> -SourceDir <dir> builds one image in AWS CodeBuild (no local Docker needed): it zips the
  source (never .git, node_modules, target, .env, keys or credentials data files; source code such as credentials.py is kept; the excluded paths are printed), uploads it to
  the data bucket, starts the build, waits and prints the resulting repo@sha256 digest. deploy -Service <name>
  (-Digest sha256:... | -FromBuild <id> | -Rollback) writes the digest to SSM Parameter Store and runs the
  pulso-deploy-<workload> command on the host: no instance is replaced and no terraform apply is needed.

  Safety properties (asserted by scripts/tests/aws-prod.Tests.ps1):
   - -Profile is mandatory; the profile names default, payana*, higo*, standar*, management* are refused unless
     -AllowAnyProfile is passed.
   - Nothing is ever applied or destroyed without a saved plan file, a printed plan summary and the typed word
     APPLY (or DESTROY). apply and destroy have no auto-approve and no flag that skips the prompt (deploy -Yes skips only the DEPLOY prompt).
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
        'status', 'upload', 'destroy-plan', 'destroy', 'deploy', 'set-secret', 'seed-secret-keys')]
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
    [string]$Service = '',
    [string]$SourceDir = '',
    [string]$Dockerfile = '',
    [string[]]$BuildArg = @(),
    [string]$ViteApiUrl = '',
    [string]$SecretKey = '',
    [string]$MirrorImage = '',
    [string]$Digest = '',
    [string]$FromBuild = '',
    [switch]$Wait,
    [switch]$Rollback,
    [switch]$Yes,
    [string]$Stage = '',
    [string]$Builder = 'codebuild',
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
    # Comment lines (first non-space char '#') are documentation, not values: the examples mention <registry> in prose.
    $values = (Get-Content -LiteralPath $file | Where-Object { $_ -notmatch '^\s*#' }) -join "`n"
    if ($values -match 'REPLACE_WITH|<registry>') { throw "$file still has placeholders (REPLACE_WITH_..., <registry>). Run aws-prod.ps1 images, or fill them by hand." }
    $file
}

function Initialize-Env([string]$Account) {
    $backend = Write-BackendHcl $Account
    Invoke-Tf (Get-EnvDir) @('init', '-input=false', '-reconfigure', "-backend-config=$backend")
}

function Set-ImagesInTfvars([string]$File, [hashtable]$Refs) {
    # Rewrites only the images = { ... } block; everything else in the file is preserved. The optional keys of the full profile
    # (agent, tools: agent services; pipeline: loader; forwarder: OTLP) are kept whenever the caller has them (a placeholder stays a
    # placeholder until its image is built), so building one service never drops the digest or the slot of another. The legacy
    # core-runtime digest is written when it is real, or when the profile has no agent image (a placeholder is then kept on purpose:
    # Resolve-VarFile refuses it until the image is built).
    $has = { param($k) $Refs.ContainsKey($k) -and $Refs[$k] }
    $real = { param($k) (& $has $k) -and ([string]$Refs[$k] -notmatch 'REPLACE_WITH|<registry>') }
    $line = { param($k, $w) "    $($k.PadRight($w)) = `"$($Refs[$k])`"" }
    $core = @()
    if ((& $real 'core') -or -not (& $has 'agent')) { $core += & $line 'core' 7 }
    $core += & $line 'gateway' 7
    foreach ($k in 'agent', 'tools', 'forwarder') { if (& $has $k) { $core += & $line $k 7 } }
    $engine = @((& $line 'pulso' 5), (& $line 'proxy' 5))
    foreach ($k in 'pipeline', 'forwarder') { if (& $has $k) { $engine += & $line $k 5 } }
    $block = @"
images = {
  core = {
$($core -join "`n")
  }
  platform = {
    support_api = "$($Refs['support_api'])"
    support_web = "$($Refs['support_web'])"
    proxy       = "$($Refs['proxy'])"
  }
  engine = {
$($engine -join "`n")
  }
}
"@
    if (-not (Test-Path -LiteralPath $File)) { Copy-Item (Join-Path (Get-EnvDir) 'prod.tfvars.example') $File }
    $text = Get-Content -Raw $File
    $new = [regex]::Replace($text, '(?ms)^images\s*=\s*\{.*?^\}\s*$', { param($m) $block.TrimEnd() })
    if ($new -eq $text -and $text -notmatch '(?m)^images\s*=') { $new = $text.TrimEnd() + "`n`n" + $block + "`n" }
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
    $refs.core = Invoke-ReleaseImage $prof $registry 'prod/core-runtime' (Join-Path $p.PulsoDir 'core-bridge') 'core-runtime' (Join-Path $p.PulsoDir 'core-bridge/Dockerfile') @("core=$($p.AgentCoreDir)")
    $refs.gateway = Invoke-ReleaseImage $prof $registry 'prod/llm-gateway' $p.LlmGatewayDir 'llm-gateway' (Join-Path $p.LlmGatewayDir 'Dockerfile')
    $refs.support_api = Invoke-ReleaseImage $prof $registry 'prod/support-platform-api' (Join-Path $p.SupportPlatformDir 'backend') 'support-platform-api'
    $refs.support_web = Invoke-ReleaseImage $prof $registry 'prod/support-platform-web' (Join-Path $p.SupportPlatformDir 'frontend') 'support-platform-web'
    $refs.proxy = Invoke-MirrorCaddy $prof $registry $p.CaddyUpstreamDigest
    $file = if ($p.VarFile) { $p.VarFile } else { Join-Path (Get-EnvDir) 'prod.tfvars' }
    Set-ImagesInTfvars $file $refs
    Write-Host "Wrote image digests to $file (uncommitted, ignored by Git)."
}

# ---------------------------------------------------------------------------------------------------------------------
# Cloud image builds (images -Service) and deploys (deploy). docs/service-deployment.md
# ---------------------------------------------------------------------------------------------------------------------
$script:EcrPrefix = 'pulso-prod'
$script:SsmPrefix = '/pulso'
$script:Services = [ordered]@{
    'core-runtime'         = @{ Key = 'core'; Workloads = @('core'); Aliases = @('agent-core', 'core') }
    'llm-gateway'          = @{ Key = 'gateway'; Workloads = @('core'); Aliases = @('gateway') }
    'support-platform-api' = @{ Key = 'support_api'; Workloads = @('platform'); Aliases = @('support-api', 'support_api') }
    'support-platform-web' = @{ Key = 'support_web'; Workloads = @('platform'); Aliases = @('support-web', 'support_web') }
    'pulso-engine'         = @{ Key = 'pulso'; Workloads = @('engine'); Aliases = @('engine', 'pulso') }
    'caddy'                = @{ Key = 'proxy'; Workloads = @('platform', 'engine'); Aliases = @('proxy') }
    # Agent services (agent_services_enabled, docs/agent-services.md): agent-core `serve` from the agent-core repo's own
    # Dockerfile (not core-bridge; the alias agent-core stays with core-runtime) and the tool-service.
    'agent-core-serve'     = @{ Key = 'agent'; Workloads = @('core'); Aliases = @('agent-serve', 'agent') }
    'tool-service'         = @{ Key = 'tools'; Workloads = @('core'); Aliases = @('tools') }
    # Automatic loader (auto_loader_enabled, docs/auto-loader.md): the data-pipeline repository's own Dockerfile.
    'data-pipeline'        = @{ Key = 'pipeline'; Workloads = @('engine'); Aliases = @('pipeline') }
    # OTLP forwarder sidecars (otlp_forwarder_enabled, docs/otlp-forwarder.md): the engine repo's scripts/o11y packaged by docker/otlp-forwarder.Dockerfile.
    'otlp-forwarder'       = @{ Key = 'forwarder'; Workloads = @('core', 'engine'); Aliases = @('forwarder') }
}

function Resolve-Service([string]$Name) {
    $n = $Name.Trim().ToLowerInvariant()
    foreach ($canonical in $script:Services.Keys) {
        $s = $script:Services[$canonical]
        if ($n -eq $canonical -or $s.Aliases -contains $n) {
            return [pscustomobject]@{ Name = $canonical; Key = $s.Key; Workloads = @($s.Workloads); Repository = "$($script:EcrPrefix)/$canonical" }
        }
    }
    throw "Unknown service '$Name'. Valid services: $($script:Services.Keys -join ', ') (aliases: agent-core, engine, support-api, support-web)."
}

function Get-DataBucket([string]$Account) { "pulso-prod-data-$Account" }
function Get-Registry([string]$Account) { "$Account.dkr.ecr.$($script:Region).amazonaws.com" }

$script:ExcludedNames = @('.git', 'node_modules', 'target', '.venv', 'venv', '__pycache__', '.terraform', '.scratch', '.idea', '.vscode', '.aws', '.ssh')
# Hard secret patterns: excluded whatever the extension (id_rsa.py stays out, foo.pem stays out).
$script:ExcludedPatterns = @('.env', '.env.*', '*.pem', '*.key', '*.p12', '*.pfx', '*.jks', '*.keystore', 'id_rsa*', 'id_ed25519*', 'id_ecdsa*',
    '*.tfstate', '*.tfstate.*', '*.tfvars', '.npmrc', '.pypirc', '.netrc', '.dockercfg', '*.secret')
# Name-only patterns: they match data-like files (credentials.json, secrets.yaml) but also source code the app imports
# (cc_platform/application/ai/credentials.py). Files with a SOURCE extension are exempt from these; directories are not.
$script:NameOnlyPatterns = @('*credentials*', 'secrets.*', '*.secrets')
$script:SourceExtensions = @('.py', '.rs', '.ts', '.tsx', '.js', '.go')
$script:KeptNames = @('.env.example', '.env.sample', '.env.template')

function Test-ExcludedPath([string]$RelativePath, [switch]$Directory) {
    $name = ($RelativePath -replace '\\', '/').TrimEnd('/').Split('/')[-1]
    if ($script:KeptNames -contains $name.ToLowerInvariant()) { return $false }
    if ($script:ExcludedNames -contains $name) { return $true }
    foreach ($pattern in $script:ExcludedPatterns) { if ($name -like $pattern) { return $true } }
    $isSource = (-not $Directory) -and ($script:SourceExtensions -contains [IO.Path]::GetExtension($name).ToLowerInvariant())
    if (-not $isSource) { foreach ($pattern in $script:NameOnlyPatterns) { if ($name -like $pattern) { return $true } } }
    $false
}

function New-SourceZip([string]$ZipPath, [object[]]$Roots) {
    # Zips the roots with forward-slash entry names (Linux unzip in CodeBuild), pruning excluded directories without
    # walking them. Returns the file count, the size and the list of excluded paths.
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $excluded = New-Object System.Collections.Generic.List[string]
    $count = 0
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, 'Create')
    try {
        foreach ($root in $Roots) {
            $base = (Resolve-Path -LiteralPath $root.Dir).ProviderPath.TrimEnd('\', '/')
            $prefix = if ($root.Prefix) { $root.Prefix.Trim('/') + '/' } else { '' }
            # Each pending directory carries its own relative path: the root can come back as an 8.3 short path
            # (C:\Users\RUNNER~1) while children report long names, so FullName.Substring($base.Length) is not safe.
            $pending = New-Object System.Collections.Generic.Stack[object]
            $pending.Push(@{ Dir = $base; Rel = '' })
            while ($pending.Count -gt 0) {
                $node = $pending.Pop()
                $dir = $node.Dir
                foreach ($item in (Get-ChildItem -LiteralPath $dir -Force)) {
                    $rel = $node.Rel + $item.Name
                    $suffix = if ($item.PSIsContainer) { '/' } else { '' }
                    if ((Test-ExcludedPath $rel -Directory:$item.PSIsContainer) -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { $excluded.Add("$prefix$rel$suffix"); continue }
                    if ($item.PSIsContainer) { $pending.Push(@{ Dir = $item.FullName; Rel = "$rel/" }); continue }
                    if ($rel -eq '.dockerignore' -and @($root.AllowInDockerignore).Count) {
                        # Staged context: a .dockerignore that excludes a path the Dockerfile needs (agent-core excludes
                        # contracts, but core-bridge/Dockerfile reads contracts/VERSION) is rewritten without those lines.
                        $allow = @($root.AllowInDockerignore)
                        $kept = @(Get-Content -LiteralPath $item.FullName | Where-Object { $allow -notcontains $_.Trim().Trim('/') })
                        $entry = $zip.CreateEntry("$prefix$rel", [IO.Compression.CompressionLevel]::Optimal)
                        $w = New-Object IO.StreamWriter($entry.Open(), (New-Object Text.UTF8Encoding($false)))
                        try { $w.Write((($kept -join "`n") + "`n")) } finally { $w.Dispose() }
                        $count++
                        continue
                    }
                    [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $item.FullName, "$prefix$rel", [IO.Compression.CompressionLevel]::Optimal) | Out-Null
                    $count++
                }
            }
        }
    } finally { $zip.Dispose() }
    [pscustomobject]@{ Files = $count; Bytes = (Get-Item -LiteralPath $ZipPath).Length; Excluded = $excluded.ToArray() }
}

function New-BuildId {
    if ($env:AWS_PROD_BUILD_ID) { return $env:AWS_PROD_BUILD_ID }
    (Get-Date).ToUniversalTime().ToString('yyyyMMddHHmmss') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6)
}

function Confirm-Deploy($p) {
    if ($p.Yes) { Write-Host 'Confirmation skipped because -Yes was passed.'; return }
    Read-TypedWord 'DEPLOY'
}

function Get-ImageRefsFromTfvars([string]$File) {
    $src = if (Test-Path -LiteralPath $File) { $File } else { Join-Path (Get-EnvDir) 'prod.tfvars.example' }
    $m = [regex]::Match((Get-Content -Raw $src), '(?ms)^images\s*=\s*\{.*?^\}\s*$')
    $refs = @{}
    foreach ($k in 'core', 'gateway', 'support_api', 'support_web', 'pulso', 'proxy') {
        $mm = if ($m.Success) { [regex]::Match($m.Value, "(?m)^\s*$k\s*=\s*`"([^`"]*)`"") } else { $null }
        $refs[$k] = if ($mm -and $mm.Success) { $mm.Groups[1].Value } else { "<registry>/$($script:EcrPrefix)/REPLACE_WITH_64_HEX_DIGEST" }
    }
    # Optional keys of the full profile: only when the file already has them (never a placeholder for a service that is off).
    foreach ($k in 'agent', 'tools', 'pipeline', 'forwarder') {
        $mm = if ($m.Success) { [regex]::Match($m.Value, "(?m)^\s*$k\s*=\s*`"([^`"]*)`"") } else { $null }
        if ($mm -and $mm.Success) { $refs[$k] = $mm.Groups[1].Value }
    }
    $refs
}

function Save-ImageRecord($p, $svc, [string]$Ref, [string]$Digest, [string]$BuildId) {
    $file = if ($p.VarFile) { $p.VarFile } else { Join-Path (Get-EnvDir) 'prod.tfvars' }
    $refs = Get-ImageRefsFromTfvars $file
    $refs[$svc.Key] = $Ref
    Set-ImagesInTfvars $file $refs
    $stateFile = Join-Path (Get-WorkDir) 'images-state.json'
    $state = [ordered]@{}
    if (Test-Path -LiteralPath $stateFile) {
        $old = Get-Content -Raw $stateFile | ConvertFrom-Json
        foreach ($prop in $old.PSObject.Properties) { $state[$prop.Name] = $prop.Value }
    }
    $state[$svc.Name] = [ordered]@{ image = $Ref; digest = $Digest; build_id = $BuildId; recorded_utc = (Get-Date).ToUniversalTime().ToString('o') }
    [IO.File]::WriteAllText($stateFile, ($state | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Write-Host "Recorded $($svc.Name) in $file (uncommitted, ignored by Git) and in $stateFile."
}

function Read-BuildRecord([string]$AwsProfile, [string]$Account, $svc, [string]$BuildId) {
    $key = "engine/build-out/$($svc.Name)/$BuildId.json"
    $json = (Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('s3', 'cp', "s3://$(Get-DataBucket $Account)/$key", '-')) -join "`n"
    $rec = $json | ConvertFrom-Json
    $pattern = '^' + [regex]::Escape("$(Get-Registry $Account)/$($svc.Repository)") + '@(sha256:[0-9a-f]{64})$'
    if (-not $rec.image -or $rec.image -notmatch $pattern) { throw "The build record $key holds an unexpected image '$($rec.image)'; expected $(Get-Registry $Account)/$($svc.Repository)@sha256:<64 hex>." }
    [pscustomobject]@{ Image = $rec.image; Digest = $Matches[1] }
}

# Free-plan fallback: build on the core host (images -Builder host). The CodeBuild small compute type may OOM on the Rust
# release build; the core host (m7i-flex.large, 8 GB) builds with docker buildx through SSM Run Command instead.
# Same inputs and outputs as the CodeBuild path: the source zip in S3, a build record in engine/build-out/.
$script:HostBuild = @{
    'core-runtime'         = @{ Dockerfile = 'core-bridge/Dockerfile'; Context = 'core-bridge'; CoreContext = 'agent-core' }
    'llm-gateway'          = @{ Dockerfile = 'Dockerfile'; Context = '.'; CoreContext = '' }
    'support-platform-api' = @{ Dockerfile = 'backend/Dockerfile'; Context = 'backend'; CoreContext = '' }
    'support-platform-web' = @{ Dockerfile = 'frontend/Dockerfile'; Context = 'frontend'; CoreContext = '' }
    'pulso-engine'         = @{ Dockerfile = 'Dockerfile'; Context = '.'; CoreContext = '' }
    'agent-core-serve'     = @{ Dockerfile = 'Dockerfile'; Context = '.'; CoreContext = '' }
    'tool-service'         = @{ Dockerfile = 'Dockerfile'; Context = '.'; CoreContext = '' }
    'data-pipeline'        = @{ Dockerfile = 'Dockerfile'; Context = '.'; CoreContext = '' }
    'otlp-forwarder'       = @{ Dockerfile = 'docker/otlp-forwarder.Dockerfile'; Context = '.'; CoreContext = '' }
}

function ConvertTo-BashQuoted([string]$Value) { "'" + ($Value -replace "'", "'\''") + "'" }

function New-HostBuildLines($svc, [string]$Bucket, [string]$Registry, [string]$BuildId, [string]$SrcKey, [string]$Dockerfile, [string[]]$BuildArg, [string]$MirrorImage) {
    $q = { param($v) ConvertTo-BashQuoted ([string]$v) }
    $repoUri = "$Registry/$($svc.Repository)"
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add('set -euo pipefail')
    $lines.Add('export DOCKER_BUILDKIT=1 AWS_DEFAULT_REGION=' + $script:Region)
    $lines.Add('REGISTRY=' + (& $q $Registry))
    $lines.Add('REPO=' + (& $q $svc.Repository))
    $lines.Add('SERVICE=' + (& $q $svc.Name))
    $lines.Add('BUILD_ID=' + (& $q $BuildId))
    $lines.Add('REPO_URI="$REGISTRY/$REPO"')
    $lines.Add('TAG="build-$BUILD_ID"')
    $lines.Add('W=/srv/build/$BUILD_ID')
    $lines.Add('mkdir -p "$W"; trap ''rm -rf "$W"'' EXIT; cd "$W"')
    $lines.Add('# The Rust release build needs more than the stack leaves free: add swap once.')
    $lines.Add('if ! swapon --show | grep -q .; then fallocate -l 4G /var/build-swap && chmod 600 /var/build-swap && mkswap /var/build-swap && swapon /var/build-swap; fi')
    $lines.Add('aws ecr get-login-password --region ' + $script:Region + ' | docker login --username AWS --password-stdin "$REGISTRY"')
    if ($MirrorImage) {
        $lines.Add('MIRROR=' + (& $q $MirrorImage))
        $lines.Add('docker pull --platform linux/amd64 "$MIRROR"')
        $lines.Add('docker tag "$MIRROR" "$REPO_URI:$TAG"')
    } else {
        $hb = $script:HostBuild[$svc.Name]
        $df = if ($Dockerfile) { $Dockerfile } else { $hb.Dockerfile }
        $lines.Add('command -v unzip >/dev/null 2>&1 || dnf install -y unzip')
        $lines.Add('docker buildx version >/dev/null 2>&1 || { install -d /usr/local/lib/docker/cli-plugins; curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-buildx https://github.com/docker/buildx/releases/download/v0.17.1/buildx-v0.17.1.linux-amd64; chmod +x /usr/local/lib/docker/cli-plugins/docker-buildx; }')
        $lines.Add('aws s3 cp ' + (& $q "s3://$Bucket/$SrcKey") + ' src.zip --region ' + $script:Region + ' --only-show-errors')
        $lines.Add('unzip -q src.zip -d src')
        $extra = ''
        if ($hb.CoreContext) { $extra += ' --build-context core="$W/src/' + $hb.CoreContext + '"' }
        foreach ($a in @($BuildArg)) { if ($a) { $extra += ' --build-arg ' + (& $q $a) } }
        # --no-cache: agent-core's Dockerfile builds its project wheel through a uv cache mount that persists on this host and can hand back a
        # wheel built from OLDER sources (image labelled with the new SHA, old code; seen 2026-10-05 in the prod-like rehearsal).
        $lines.Add('docker buildx build --pull --no-cache --load -f "$W/src/' + $df + '"' + $extra + ' -t "$REPO_URI:$TAG" "$W/src/' + $hb.Context + '"')
    }
    $lines.Add('docker push "$REPO_URI:$TAG"')
    $lines.Add('DIGEST=$(aws ecr describe-images --repository-name "$REPO" --image-ids "imageTag=$TAG" --region ' + $script:Region + ' --query ''imageDetails[0].imageDigest'' --output text)')
    $lines.Add('[[ "$DIGEST" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "no digest recorded for $TAG"; exit 1; }')
    $lines.Add('printf ''{"image":"%s@%s","digest":"%s"}\n'' "$REPO_URI" "$DIGEST" "$DIGEST" > build-record.json')
    $lines.Add('aws s3 cp build-record.json ' + (& $q "s3://$Bucket/engine/build-out/$($svc.Name)/$BuildId.json") + ' --region ' + $script:Region + ' --only-show-errors')
    $lines.Add('echo "IMAGE=$REPO_URI@$DIGEST"')
    , $lines.ToArray()
}

function Invoke-HostBuild([string]$AwsProfile, $svc, [string]$Bucket, [string]$Registry, [string]$BuildId, [string]$SrcKey, $p, [bool]$Mirror) {
    $found = ((Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ec2', 'describe-instances', '--filters', 'Name=tag:Workload,Values=core', 'Name=instance-state-name,Values=running',
                '--query', 'Reservations[].Instances[].InstanceId', '--output', 'text')) -join ' ').Trim()
    $instance = ($found -split '\s+' | Where-Object { $_ -match '^i-[0-9a-f]{8,17}$' } | Select-Object -First 1)
    if (-not $instance) { throw 'No running core host found (tag Workload=core). Apply the compute stage first, or use -Builder codebuild.' }
    Write-Host "Builder       : core host $instance (SSM Run Command + docker buildx; no CodeBuild)"
    $lines = New-HostBuildLines $svc $Bucket $Registry $BuildId $SrcKey $p.Dockerfile @($p.BuildArg) $(if ($Mirror) { $p.MirrorImage } else { '' })
    $file = Join-Path (Get-WorkDir) "host-build-$BuildId.json"
    $doc = [ordered]@{ commands = @($lines); executionTimeout = @('3600') }
    [IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $cmdId = ((Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ssm', 'send-command', '--instance-ids', $instance, '--document-name', 'AWS-RunShellScript',
                '--parameters', ('file://' + ($file -replace '\\', '/')), '--comment', "pulso image build $($svc.Name) $BuildId", '--query', 'Command.CommandId', '--output', 'text')) -join '').Trim()
    Write-Host "Started command $cmdId on $instance"
    $result = @(Wait-DeployCommand $AwsProfile $cmdId)
    $tail = ''
    try { $tail = ((Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ssm', 'get-command-invocation', '--command-id', $cmdId, '--instance-id', $instance, '--query', 'StandardOutputContent', '--output', 'text')) -join "`n") } catch { }
    if ($tail) { Write-Host ($tail.Split("`n") | Select-Object -Last 15 | ForEach-Object { "  | $_" } | Out-String).TrimEnd() }
    if ($result.Count -eq 0 -or ($result | Where-Object { $_.Status -ne 'Success' })) {
        throw "Host build command $cmdId ended with status $(($result | ForEach-Object { $_.Status }) -join ','). Output: aws ssm get-command-invocation --command-id $cmdId --instance-id $instance --profile $AwsProfile --region $($script:Region)"
    }
}

function Invoke-ImagesCloud($p, $id) {
    $svc = Resolve-Service $p.Service
    $builder = if ($p.Builder) { $p.Builder } else { 'codebuild' }
    if ($builder -notin 'codebuild', 'host') { throw "-Builder must be codebuild (default) or host (build on the core host through SSM), got '$builder'." }
    $hostBuild = $builder -eq 'host'
    $mirror = $svc.Name -eq 'caddy'
    if ($mirror) {
        if (-not $p.MirrorImage -or $p.MirrorImage -notmatch '^[a-z0-9][a-zA-Z0-9./:_@-]{2,250}$') { throw 'caddy is mirrored from upstream: pass -MirrorImage <docker.io/library/caddy:TAG or docker.io/library/caddy@sha256:DIGEST>.' }
    } else {
        if (-not $p.SourceDir -or -not (Test-Path -LiteralPath $p.SourceDir -PathType Container)) { throw "images -Service $($svc.Name) needs -SourceDir <existing directory>." }
        if ($svc.Name -eq 'core-runtime' -and (-not $p.AgentCoreDir -or -not (Test-Path -LiteralPath $p.AgentCoreDir -PathType Container))) { throw 'images -Service core-runtime needs -AgentCoreDir <the pinned agent-core checkout>.' }
    }
    if ($p.ViteApiUrl) {
        if ($svc.Name -ne 'support-platform-web') { throw "-ViteApiUrl only applies to support-platform-web (the frontend build arg VITE_API_URL), not $($svc.Name)." }
        # "/" is the same-origin build (support-platform: the SPA calls /api/* and the WebSocket on its own origin, as behind CloudFront).
        if ($p.ViteApiUrl -ne '/' -and $p.ViteApiUrl -notmatch '^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[A-Za-z0-9._~/-]*)?$') { throw "-ViteApiUrl must be / (same origin) or an http(s) URL without spaces, commas, query or credentials, got '$($p.ViteApiUrl)'." }
        if (@($p.BuildArg) | Where-Object { $_ -like 'VITE_API_URL=*' }) { throw 'Pass the API URL with -ViteApiUrl or with -BuildArg VITE_API_URL=..., not both (VITE_API_URL is set twice).' }
        $p.BuildArg = @(@($p.BuildArg) | Where-Object { $_ }) + "VITE_API_URL=$($p.ViteApiUrl)"
    }
    foreach ($a in @($p.BuildArg)) { if ($a -and ($a -notmatch '^[A-Za-z_][A-Za-z0-9_]*=[^,\s]*$')) { throw "-BuildArg must be KEY=VALUE without spaces or commas, got '$a'." } }

    $buildId = New-BuildId
    if ($buildId -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw "Invalid build id '$buildId'." }
    $bucket = Get-DataBucket $id.Account
    $registry = Get-Registry $id.Account
    $project = "pulso-prod-build-$($svc.Name)"
    $srcKey = "engine/build-src/$($svc.Name)/$buildId.zip"

    Write-Host "Service       : $($svc.Name) -> $registry/$($svc.Repository)"
    if (-not $hostBuild) { Write-Host "Build project : $project (AWS CodeBuild, linux x86_64, privileged docker)" }
    $zip = $null
    if ($mirror) {
        Write-Host "Mirror        : $($p.MirrorImage) (pulled by CodeBuild, pushed to $($svc.Repository))"
    } else {
        $roots = @(@{ Dir = $p.SourceDir; Prefix = '' })
        if ($svc.Name -eq 'core-runtime') { $roots += @{ Dir = $p.AgentCoreDir; Prefix = 'agent-core'; AllowInDockerignore = @('contracts') } }
        # The forwarder recipe lives in THIS repository (docker/otlp-forwarder.Dockerfile); the engine repo has none. Added unless the source already has it.
        if ($svc.Name -eq 'otlp-forwarder' -and -not (Test-Path -LiteralPath (Join-Path $p.SourceDir 'docker/otlp-forwarder.Dockerfile'))) { $roots += @{ Dir = (Join-Path $script:RepoRoot 'docker'); Prefix = 'docker' } }
        $zip = Join-Path (Get-WorkDir) "build-src-$buildId.zip"
        $r = New-SourceZip -ZipPath $zip -Roots $roots
        Write-Host ("Source upload : s3://$bucket/$srcKey ({0} files, {1:N1} MB)" -f $r.Files, ($r.Bytes / 1MB))
        Write-Host "Excluded ($($r.Excluded.Count) paths, never uploaded):"
        $r.Excluded | Select-Object -First 60 | ForEach-Object { Write-Host "  - $_" }
        if ($r.Excluded.Count -gt 60) { Write-Host "  ... and $($r.Excluded.Count - 60) more" }
        if ($r.Bytes -gt 1GB) { throw 'The source zip is larger than 1 GB: exclude build output or large data from the source directory.' }
    }
    if ($p.Dockerfile) { Write-Host "Dockerfile    : $($p.Dockerfile) (inside the zip)" }
    if (@($p.BuildArg).Count) { Write-Host "Build args    : $((@($p.BuildArg) -join ' '))" }
    Write-Host "Build id      : $buildId (the build record goes to s3://$bucket/engine/build-out/$($svc.Name)/$buildId.json)"
    Write-Host $(if ($hostBuild) { 'This uploads the zip to S3 and runs docker build on the core host (it shares CPU and memory with the stack). Nothing is deployed.' } else { 'This uploads the zip to S3 and starts a paid CodeBuild build. Nothing is deployed.' })
    Confirm-Deploy $p

    $prof = $p.Profile
    if ($zip) { Invoke-Aws -AwsProfile $prof -CliArgs @('s3', 'cp', $zip, "s3://$bucket/$srcKey") | Out-Null }
    if ($hostBuild) {
        Invoke-HostBuild $prof $svc $bucket $registry $buildId $srcKey $p $mirror
    } else {
        $startArgs = @('codebuild', 'start-build', '--project-name', $project)
        if ($zip) { $startArgs += @('--source-location-override', "$bucket/$srcKey") }
        $overrides = @("name=SOURCE_ID,value=$buildId,type=PLAINTEXT")
        if ($p.Dockerfile) { $overrides += "name=DOCKERFILE,value=$($p.Dockerfile),type=PLAINTEXT" }
        if (@($p.BuildArg).Count) { $overrides += "name=BUILD_ARGS,value=$(@($p.BuildArg) -join ' '),type=PLAINTEXT" }
        if ($mirror) { $overrides += "name=MIRROR_IMAGE,value=$($p.MirrorImage),type=PLAINTEXT" }
        $startArgs += @('--environment-variables-override') + $overrides + @('--query', 'build.id', '--output', 'text')
        $awsBuildId = ((Invoke-Aws -AwsProfile $prof -CliArgs $startArgs) -join '').Trim()
        Write-Host "Started build $awsBuildId"

        $status = ''
        for ($i = 0; $i -lt 520; $i++) {
            $now = ((Invoke-Aws -AwsProfile $prof -CliArgs @('codebuild', 'batch-get-builds', '--ids', $awsBuildId, '--query', 'builds[0].buildStatus', '--output', 'text')) -join '').Trim()
            if ($now -ne $status) { Write-Host "Build status: $now"; $status = $now }
            if ($status -ne 'IN_PROGRESS') { break }
            Start-Sleep -Seconds 15
        }
        if ($status -ne 'SUCCEEDED') {
            throw "Build $awsBuildId ended with status $status. Logs: aws logs tail /aws/codebuild/$project --since 2h --profile $prof --region $($script:Region)"
        }
    }
    $rec = Read-BuildRecord $prof $id.Account $svc $buildId
    Write-Host ''
    Write-Host "IMAGE $($rec.Image)"
    Save-ImageRecord $p $svc $rec.Image $rec.Digest $buildId
    Write-Host "Deploy it with: aws-prod.ps1 deploy -Profile $prof -Service $($svc.Name) -FromBuild $buildId -Wait"
}

function Get-SsmParameterName([string]$Workload, [string]$Key) { "$($script:SsmPrefix)/$Workload/images/$Key" }

function Assert-DigestInEcr([string]$AwsProfile, $svc, [string]$Digest) {
    try {
        Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ecr', 'describe-images', '--repository-name', $svc.Repository, '--image-ids', "imageDigest=$Digest",
            '--query', 'imageDetails[0].imageDigest', '--output', 'text') | Out-Null
    } catch { throw "Digest $Digest not found in ECR repository $($svc.Repository). Build and push it first (aws-prod.ps1 images -Service $($svc.Name) ...)." }
}

function Wait-DeployCommand([string]$AwsProfile, [string]$CommandId) {
    $terminal = 'Success', 'Failed', 'TimedOut', 'Cancelled', 'Cancelling'
    $rows = @()
    for ($i = 0; $i -lt 200; $i++) {
        $rows = @(Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('ssm', 'list-command-invocations', '--command-id', $CommandId,
                '--query', 'CommandInvocations[].[InstanceId,Status]', '--output', 'text') | Where-Object { $_ -and $_.Trim() })
        $parsed = @($rows | ForEach-Object { $f = $_.Trim() -split '\s+'; [pscustomobject]@{ Instance = $f[0]; Status = $f[1] } })
        if ($parsed.Count -gt 0 -and -not ($parsed | Where-Object { $terminal -notcontains $_.Status })) { return $parsed }
        Start-Sleep -Seconds 5
    }
    throw "Command $CommandId did not finish in time. Read it later: aws ssm list-command-invocations --command-id $CommandId --profile $AwsProfile --region $($script:Region)"
}

function Invoke-Deploy($p, $id) {
    if (-not $p.Service) { throw 'deploy needs -Service <name>.' }
    $svc = Resolve-Service $p.Service
    $modes = @(@($p.Digest, $p.FromBuild) | Where-Object { $_ }).Count + [int][bool]$p.Rollback
    if ($modes -eq 0) { throw 'deploy needs one of -Digest sha256:<64 hex>, -FromBuild <build id> or -Rollback.' }
    if ($modes -gt 1) { throw 'deploy takes only one of -Digest, -FromBuild and -Rollback.' }
    $prof = $p.Profile
    $registry = Get-Registry $id.Account

    $newDigest = ''
    if ($p.Digest) {
        if ($p.Digest -notmatch '^sha256:[0-9a-f]{64}$') { throw "A sha256 digest is required (sha256:<64 hex>), got '$($p.Digest)'." }
        $newDigest = $p.Digest
    } elseif ($p.FromBuild) {
        if ($p.FromBuild -notmatch '^[A-Za-z0-9._-]{1,64}$') { throw "Invalid build id '$($p.FromBuild)'." }
        $newDigest = (Read-BuildRecord $prof $id.Account $svc $p.FromBuild).Digest
    }
    if ($newDigest) { Assert-DigestInEcr $prof $svc $newDigest }

    $plan = @()
    foreach ($w in $svc.Workloads) {
        $name = Get-SsmParameterName $w $svc.Key
        $current = ((Invoke-Aws -AwsProfile $prof -CliArgs @('ssm', 'get-parameter', '--name', $name, '--query', 'Parameter.Value', '--output', 'text')) -join '').Trim()
        if ($p.Rollback) {
            $hist = @((Invoke-Aws -AwsProfile $prof -CliArgs @('ssm', 'get-parameter-history', '--name', $name, '--query', 'Parameters[].Value', '--output', 'json')) -join "`n" | ConvertFrom-Json)
            $earlier = @($hist | Where-Object { $_ -and $_ -ne $current })
            if ($earlier.Count -eq 0) { throw "There is no previous value in the history of $name to roll back to." }
            $ref = $earlier[-1]
            if ($ref -notmatch '@(sha256:[0-9a-f]{64})$') { throw "The previous value '$ref' of $name is not a digest-pinned image." }
            Assert-DigestInEcr $prof $svc $Matches[1]
        } else {
            $ref = "$registry/$($svc.Repository)@$newDigest"
        }
        $plan += [pscustomobject]@{ Workload = $w; Parameter = $name; Current = $current; New = $ref; Document = "pulso-deploy-$w" }
    }

    Write-Host "Deploy $($svc.Name)$(if ($p.Rollback) { ' (ROLLBACK to the previous digest)' }):"
    foreach ($s in $plan) {
        Write-Host "  1. ssm put-parameter $($s.Parameter)"
        Write-Host "       from $($s.Current)"
        Write-Host "       to   $($s.New)"
        Write-Host "  2. ssm send-command document $($s.Document) to the instance tagged Workload=$($s.Workload) (pull, up -d, wait healthy, restore on failure)"
    }
    Write-Host $(if ($p.Wait) { '  3. wait for the result and print the health; if the host rolls back, the SSM parameter is restored.' } else { '  3. do not wait (add -Wait to wait, print the health and restore the parameter on failure).' })
    Confirm-Deploy $p

    foreach ($s in $plan) {
        Invoke-Aws -AwsProfile $prof -CliArgs @('ssm', 'put-parameter', '--name', $s.Parameter, '--value', $s.New, '--type', 'String', '--overwrite') | Out-Null
        $cmd = ((Invoke-Aws -AwsProfile $prof -CliArgs @('ssm', 'send-command', '--document-name', $s.Document, '--targets', "Key=tag:Workload,Values=$($s.Workload)",
                    '--query', 'Command.CommandId', '--output', 'text')) -join '').Trim()
        Write-Host "Sent $($s.Document) as command $cmd."
        if (-not $p.Wait) {
            Write-Host "Read the result: aws ssm list-command-invocations --command-id $cmd --details --profile $prof --region $($script:Region)"
            continue
        }
        $results = Wait-DeployCommand $prof $cmd
        $problem = ''
        foreach ($r in $results) {
            $out = (Invoke-Aws -AwsProfile $prof -CliArgs @('ssm', 'get-command-invocation', '--command-id', $cmd, '--instance-id', $r.Instance,
                    '--query', 'StandardOutputContent', '--output', 'text')) -join "`n"
            Write-Host "--- $($r.Instance) ($($r.Status)) ---"
            $out -split "`n" | ForEach-Object { Write-Host $_ }
            if ($r.Status -ne 'Success') {
                $problem = if ($out -match 'DEPLOY_RESULT=rolled_back') { "Deploy failed on $($r.Instance) and the host rolled back to the previous digests." } else { "Deploy command ended with status $($r.Status) on $($r.Instance)." }
            } elseif ($out -notmatch '(?m)^DEPLOY_RESULT=ok\s*$') {
                $problem = "The command succeeded on $($r.Instance) but did not report DEPLOY_RESULT=ok."
            }
        }
        if ($problem) {
            if ($s.Current) {
                Invoke-Aws -AwsProfile $prof -CliArgs @('ssm', 'put-parameter', '--name', $s.Parameter, '--value', $s.Current, '--type', 'String', '--overwrite') | Out-Null
                Write-Host "Restored $($s.Parameter) to its previous value so a reboot does not pull the failed digest."
            }
            throw "$problem Investigate with: docker compose -p pulso ps / logs on the host (SSM session)."
        }
        Write-Host "OK: $($svc.Name) on $($s.Workload) runs $($s.New)"
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# set-secret: one key of the single Secrets Manager secret, typed at a secure prompt. The value never touches a
# parameter, a file in the repository, the console or a log.
# ---------------------------------------------------------------------------------------------------------------------
# The ONLY keys a human types (external provider accounts). Everything else is generated or derived by Terraform (docs/secrets-wiring.md).
$script:HumanSecretKeys = @('GATEWAY__OPENROUTER_API_KEY', 'GATEWAY__JEV_API_KEY', 'LANGFUSE__LANGFUSE_PUBLIC_KEY', 'LANGFUSE__LANGFUSE_SECRET_KEY')
# One provider key, two consumers: the JEV key the human types once is also the one agent-core serve reads.
$script:SecretFanOut = @{ 'GATEWAY__JEV_API_KEY' = @('AGENT__AGENTCORE_JEV_API_KEY') }
# A derived DSN is only seeded together with the passwords it embeds (a kept password would not match a freshly generated DSN).
$script:DerivedFrom = @{
    'CORE__AGENTCORE_REGISTRY_DSN' = @('DB__DB_PASSWORD_CORE_APP'); 'CORE__AGENTCORE_EVAL_DSN' = @('DB__DB_PASSWORD_CORE_EVAL_APP')
    'AGENT__AGENTCORE_REGISTRY_DSN' = @('DB__DB_PASSWORD_AGENT_APP'); 'AGENT__AGENTCORE_EVAL_DSN' = @('DB__DB_PASSWORD_AGENT_APP')
    'AGENT__AGENTCORE_MIGRATE_DSN' = @('DB__DB_PASSWORD_AGENT_OWNER'); 'AGENT__AGENTCORE_MIGRATE_EVAL_DSN' = @('DB__DB_PASSWORD_AGENT_OWNER')
    'SUPPORT__CC_DATABASE_URL' = @('DB__DB_PASSWORD_PLATFORM_APP'); 'MIGRATE__CC_DATABASE_URL' = @('DB__DB_PASSWORD_PLATFORM_OWNER')
    'PULSO__PULSO_PG_PRODUCT_DSN' = @('DB__DB_PASSWORD_PLATFORM_EXPORTER_RO'); 'PULSO__PULSO_DATABASE_URL' = @('DB__POSTGRES_PASSWORD')
}

function Read-SecretValue([string]$Prompt) {
    $secure = Read-Host -Prompt $Prompt -AsSecureString
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-SetSecret($p, $id) {
    if ($p.SecretKey -cnotmatch '^((COMMON|CORE|GATEWAY|SUPPORT|PULSO|AGENT|TOOLS|DB|LOADER|LANGFUSE)__[A-Z][A-Z0-9_]*|FILES__(AGENT|SUPPORT)__[A-Z][A-Z0-9_]*)$') {
        throw '-SecretKey must be <SERVICE>__<VAR> with SERVICE one of COMMON, CORE, GATEWAY, SUPPORT, PULSO, AGENT, TOOLS, DB, LOADER, LANGFUSE (for example GATEWAY__OPENROUTER_API_KEY), or FILES__<AGENT|SUPPORT>__<NAME> for a value the host writes as a file.'
    }
    $name = "$($script:EcrPrefix)/hackathon"
    $prof = $p.Profile
    $current = ((Invoke-Aws -AwsProfile $prof -CliArgs @('secretsmanager', 'get-secret-value', '--secret-id', $name, '--query', 'SecretString', '--output', 'text')) -join "`n") | ConvertFrom-Json
    $existed = [bool]$current.PSObject.Properties[$p.SecretKey]
    if ($script:HumanSecretKeys -notcontains $p.SecretKey) { Write-Host "NOTE     : $($p.SecretKey) is generated or derived by Terraform, not a human key; setting it overrides the wiring (docs/human-secrets-only.md)." }
    Write-Host "Secret   : $name"
    Write-Host "Key      : $($p.SecretKey) ($(if ($existed) { 'existing key, will be replaced' } else { 'new key, will be added' }))"
    Write-Host 'The value is typed next, hidden, and is never printed or logged. All other keys are kept.'
    $value = Read-SecretValue "Value for $($p.SecretKey)"
    if ([string]::IsNullOrEmpty($value)) { throw 'The value is empty: nothing was written.' }
    if ($value -eq 'CHANGE_ME') { throw 'The value is the CHANGE_ME placeholder: nothing was written.' }
    Read-TypedWord 'SET'
    $merged = [ordered]@{}
    foreach ($prop in $current.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
    $merged[$p.SecretKey] = $value
    $also = @(); if ($script:SecretFanOut.ContainsKey($p.SecretKey)) { $also = @($script:SecretFanOut[$p.SecretKey]) }
    foreach ($k in $also) { $merged[$k] = $value }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pulso-secret-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($tmp, ($merged | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        Invoke-Aws -AwsProfile $prof -CliArgs @('secretsmanager', 'put-secret-value', '--secret-id', $name, '--secret-string', ('file://' + ($tmp -replace '\\', '/'))) | Out-Null
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $value = $null; $merged = $null
    }
    if ($also.Count) { Write-Host "Also set : $($also -join ', ') (same provider key)" }
    Write-Host "OK: $($p.SecretKey) set in $name. Hosts pick it up on the next pulso-stack restart or deploy."
}

function Get-GeneratedSecrets([string]$Dir) {
    # The sensitive output is captured into a variable, never echoed: the values stay out of the console and the logs.
    $json = (& terraform "-chdir=$Dir" output -json generated_secrets) -join "`n"
    if ($LASTEXITCODE -ne 0) { throw 'terraform output generated_secrets failed: apply the stack (or run it against the right state) first.' }
    $json
}

function Invoke-SeedSecretKeys($p, $id) {
    $name = "$($script:EcrPrefix)/hackathon"
    $prof = $p.Profile
    Initialize-Env $id.Account
    $desired = (Get-GeneratedSecrets (Get-EnvDir)) | ConvertFrom-Json
    $current = ((Invoke-Aws -AwsProfile $prof -CliArgs @('secretsmanager', 'get-secret-value', '--secret-id', $name, '--query', 'SecretString', '--output', 'text')) -join "`n") | ConvertFrom-Json
    $add = @(); $keep = @()
    foreach ($prop in $desired.PSObject.Properties) {
        $cur = $current.PSObject.Properties[$prop.Name]
        if (-not $cur -or [string]$cur.Value -eq 'CHANGE_ME' -or [string]::IsNullOrEmpty([string]$cur.Value)) { $add += $prop.Name } else { $keep += $prop.Name }
    }
    $skipped = @()
    foreach ($k in @($add)) {
        if ($script:DerivedFrom.ContainsKey($k) -and (@($script:DerivedFrom[$k] | Where-Object { $keep -contains $_ }).Count -gt 0)) { $skipped += $k; $add = @($add | Where-Object { $_ -ne $k }) }
    }
    if ($skipped.Count) { Write-Host "Skipped  : $($skipped -join ', ') (embeds a password that is already set and kept; the DSN would not match it)" }
    Write-Host "Secret   : $name"
    Write-Host "Will add : $(if ($add.Count) { $add -join ', ' } else { '(nothing)' })"
    Write-Host "Kept     : $(if ($keep.Count) { $keep -join ', ' } else { '(none)' }) (already hold a value; never overwritten)"
    Write-Host 'Every other key of the secret is kept. Values are never printed or logged.'
    if (-not $add.Count) { Write-Host 'Nothing to seed.'; return }
    Read-TypedWord 'SEED'
    $merged = [ordered]@{}
    foreach ($prop in $current.PSObject.Properties) { $merged[$prop.Name] = $prop.Value }
    foreach ($k in $add) { $merged[$k] = $desired.PSObject.Properties[$k].Value }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('pulso-secret-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [IO.File]::WriteAllText($tmp, ($merged | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
        Invoke-Aws -AwsProfile $prof -CliArgs @('secretsmanager', 'put-secret-value', '--secret-id', $name, '--secret-string', ('file://' + ($tmp -replace '\\', '/'))) | Out-Null
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force }
        $merged = $null; $desired = $null
    }
    Write-Host "OK: $($add.Count) key(s) added to $name. Restart pulso-stack (or deploy) on each host to pick them up."
}

function Invoke-PlanBuilderStage($p, $id, [string]$Work) {
    # Stage 1 of a brand-new account: network + data + the CodeBuild builder, with throw-away digests, so the images
    # can be built before the hosts exist. Run plan without -Stage afterwards for everything else.
    $registry = Get-Registry $id.Account
    $zero = 'sha256:' + ('0' * 64)
    $px = $script:EcrPrefix
    $stageFile = Join-Path $Work 'builder-stage.tfvars'
    @"
# Generated by aws-prod.ps1 plan -Stage builder: throw-away digests, never applied to the hosts.
images = {
  core = {
    core    = "$registry/$px/core-runtime@$zero"
    gateway = "$registry/$px/llm-gateway@$zero"
    agent   = "$registry/$px/agent-core-serve@$zero"
    tools   = "$registry/$px/tool-service@$zero"
    forwarder = "$registry/$px/otlp-forwarder@$zero"
  }
  platform = {
    support_api = "$registry/$px/support-platform-api@$zero"
    support_web = "$registry/$px/support-platform-web@$zero"
    proxy       = "$registry/$px/caddy@$zero"
  }
  engine = {
    pulso = "$registry/$px/pulso-engine@$zero"
    proxy = "$registry/$px/caddy@$zero"
    pipeline = "$registry/$px/data-pipeline@$zero"
    forwarder = "$registry/$px/otlp-forwarder@$zero"
  }
}
"@ | Set-Content -Encoding utf8 $stageFile
    $user = if ($p.VarFile) { $p.VarFile } else { Join-Path (Get-EnvDir) 'prod.tfvars' }
    $varArgs = @()
    if (Test-Path -LiteralPath $user) { $varArgs += "-var-file=$user" }
    $varArgs += "-var-file=$stageFile"
    Initialize-Env $id.Account
    Invoke-Tf (Get-EnvDir) (@('plan', '-input=false') + $varArgs + @('-target=module.image_builder', "-out=$(Join-Path $Work 'prod.tfplan')"))
    Show-PlanSummary (Get-EnvDir) (Join-Path $Work 'prod.tfplan')
    Write-Host 'Stage "builder" creates the network, the database, the bucket and the CodeBuild projects, not the hosts. Next: apply, then images -Service ..., then plan (without -Stage) and apply.'
}

# Names and SET/UNSET only. A value of CHANGE_ME or an empty value is UNSET. Never a value, never a length.
function Show-SecretStatus([string]$AwsProfile) {
    $name = "$($script:EcrPrefix)/hackathon"
    $json = (Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('secretsmanager', 'get-secret-value', '--secret-id', $name, '--query', 'SecretString', '--output', 'text')) -join "`n"
    $cur = $json | ConvertFrom-Json
    $json = $null
    $unset = @(); $set = 0; $present = @()
    foreach ($prop in $cur.PSObject.Properties) {
        $present += $prop.Name
        $v = [string]$prop.Value
        if ([string]::IsNullOrEmpty($v) -or $v -eq 'CHANGE_ME') { $unset += $prop.Name } else { $set++ }
    }
    $cur = $null
    Write-Host "--- secret $name (names only) ---"
    Write-Host "SET      : $set key(s)"
    # A human key ABSENT from the secret (e.g. a secret created with an older schema) is as unset as a CHANGE_ME one.
    $humanLines = @()
    foreach ($k in ($script:HumanSecretKeys | Sort-Object)) {
        $absent = $present -notcontains $k
        if (-not $absent -and $unset -notcontains $k) { continue }
        $notes = @()
        if ($absent) { $notes += 'MISSING' }
        if ($k -like 'LANGFUSE__*') { $notes += 'optional unless the otlp forwarder is on' }
        $humanLines += $(if ($notes.Count) { "$k ($($notes -join ', '))" } else { $k })
    }
    $other = @($unset | Where-Object { $script:HumanSecretKeys -notcontains $_ } | Sort-Object)
    Write-Host "UNSET (human, set with set-secret): $(if ($humanLines.Count) { $humanLines -join ', ' } else { '(none)' })"
    Write-Host "UNSET (should be wired; run seed-secret-keys): $(if ($other.Count) { $other -join ', ' } else { '(none)' })"
}

function Invoke-Status($id, [string]$AwsProfile) {
    Show-SecretStatus $AwsProfile
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
    if (-not $Command) { throw 'Usage: aws-prod.ps1 <check|root-keys-reminder|bootstrap-plan|bootstrap-apply|images|plan|apply|status|upload|destroy-plan|destroy|deploy|set-secret|seed-secret-keys> -Profile <name>' }

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
        'images' { if ($p.Service) { Invoke-ImagesCloud $p $id } else { Invoke-Images $p $id } }
        'deploy' { Invoke-Deploy $p $id }
        'set-secret' { Invoke-SetSecret $p $id }
        'seed-secret-keys' { Invoke-SeedSecretKeys $p $id }
        'plan' {
            if ($p.Stage) {
                if ($p.Stage -ne 'builder') { throw "Unknown -Stage '$($p.Stage)'. The only stage is: builder." }
                Invoke-PlanBuilderStage $p $id $work
                return
            }
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
    Service = $Service; SourceDir = $SourceDir; Dockerfile = $Dockerfile; BuildArg = $BuildArg; ViteApiUrl = $ViteApiUrl; SecretKey = $SecretKey; MirrorImage = $MirrorImage
    Digest = $Digest; FromBuild = $FromBuild; Wait = [bool]$Wait; Rollback = [bool]$Rollback; Yes = [bool]$Yes; Stage = $Stage; Builder = $Builder
}
Invoke-AwsProd -Command $Command -Profile $Profile -AllowAnyProfile ([bool]$AllowAnyProfile) -Options $options
