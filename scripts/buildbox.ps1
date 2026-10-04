<#
.SYNOPSIS
  Operate the TEMPORARY Linux build host (terraform/envs/buildbox): compile Rust and run test suites on it instead of
  on your Windows PC. See docs/buildbox.md.
.DESCRIPTION
  Subcommands: up, stop, down, status, sync, run, logs, fetch, gc, verify-gone.

  Safety properties (asserted by scripts/tests/buildbox.Tests.ps1):
   - -Profile defaults to pulso-buildbox (the scoped IAM user); the profile names default, payana*, higo*, standar* and
     management* are refused unless -AllowAnyProfile is passed. Region is always us-east-1.
   - Every state-changing subcommand says what it will do and needs you to type YES (or -Yes). `down` is different:
     it runs terraform destroy with the ADMIN profile you pass in -AdminProfile and ALWAYS needs the typed word DESTROY.
   - Nothing reads ~/.aws or any credential file; the aws CLI resolves the profile. Secrets are never passed or printed.
   - sync never uploads target/, node_modules/, .terraform/, *.tfstate*, .env files, *.pem or credential-looking files.
.EXAMPLE
  ./scripts/buildbox.ps1 up -Yes
  ./scripts/buildbox.ps1 sync -Worktree D:\wt\engine -Lane infra-1 -Yes
  ./scripts/buildbox.ps1 run -Lane infra-1 -Cmd 'cargo test -j 2 --offline --no-fail-fast' -Yes
  ./scripts/buildbox.ps1 fetch -Lane infra-1 -Id 20261004-101010-beef -Dest D:\results
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'stop', 'down', 'status', 'sync', 'run', 'logs', 'fetch', 'gc', 'verify-gone')]
    [string]$Command,
    [string]$Profile = 'pulso-buildbox',
    [switch]$AllowAnyProfile,
    [string]$AdminProfile = '',
    [string]$BackendConfig = '',
    [string]$Worktree = '',
    [string]$Lane = '',
    [string]$Id = '',
    [string]$Cmd = '',
    [int]$Jobs = 2,
    [int]$Timeout = 60,
    [string]$Dest = '',
    [int]$KeepHours = 24,
    [switch]$NoWait,
    [switch]$Yes,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

$script:Region = 'us-east-1'
$script:DefaultProfile = 'pulso-buildbox'
$script:RepoRoot = Split-Path $PSScriptRoot -Parent
$script:RefusedProfile = '^(default|payana.*|higo.*|standar.*|management.*)$'
$script:HourlyUsd = 0.34
$script:DiskMonthlyUsd = 8
$script:Excludes = @('target/', 'node_modules/', '.terraform/', '*.tfstate*', '.env', '.env.*', '*.pem', '*.key', '*.pfx', '*.p12',
    'id_rsa*', 'id_ed25519*', 'credentials*', '.aws/', '.ssh/', '.npmrc', '.pypirc')

function Get-WorkDir {
    $dir = if ($env:BUILDBOX_WORKDIR) { $env:BUILDBOX_WORKDIR } else { Join-Path $script:RepoRoot '.scratch/buildbox' }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dir
}

function Get-EnvDir { Join-Path $script:RepoRoot 'terraform/envs/buildbox' }

function Assert-Profile([string]$Name, [bool]$AllowAny) {
    if ([string]::IsNullOrWhiteSpace($Name)) { throw 'Pass -Profile <name> (default pulso-buildbox: aws configure --profile pulso-buildbox).' }
    if (-not $AllowAny -and $Name -imatch $script:RefusedProfile) {
        throw "Refusing profile '$Name': default, payana*, higo*, standar* and management* are not allowed targets. Use a dedicated profile such as pulso-buildbox, or pass -AllowAnyProfile if you are sure."
    }
}

function Assert-Lane([string]$Value) {
    if ($Value -cnotmatch '^[a-z0-9][a-z0-9-]{0,40}$') { throw "Invalid lane '$Value' (-Lane): lowercase letters, digits and dashes only (max 41 chars)." }
}

function Assert-JobId([string]$Value) {
    if ($Value -notmatch '^[A-Za-z0-9-]+$') { throw "Invalid job id '$Value': letters, digits and dashes only." }
}

function Invoke-Aws {
    # Always pins the profile and region; returns stdout lines; throws on a non-zero exit.
    param([string]$AwsProfile, [string[]]$CliArgs)
    $out = & aws @CliArgs --profile $AwsProfile --region $script:Region
    if ($LASTEXITCODE -ne 0) { throw "aws $($CliArgs[0..1] -join ' ') failed (exit $LASTEXITCODE)." }
    $out
}

function Invoke-AwsJson([string]$AwsProfile, [string[]]$CliArgs) {
    $text = (Invoke-Aws -AwsProfile $AwsProfile -CliArgs ($CliArgs + @('--output', 'json'))) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text | ConvertFrom-Json
}

function Confirm-Action([string]$What, [bool]$SkipPrompt) {
    Write-Host "This will: $What"
    if ($SkipPrompt) { return }
    $answer = Read-Host 'Type YES to continue (anything else aborts)'
    if ($answer -cne 'YES') { throw 'Aborted: you did not type YES.' }
}

function Read-TypedWord([string]$Word) {
    $answer = Read-Host "Type $Word to continue (anything else aborts)"
    if ($answer -cne $Word) { throw "Aborted: you did not type $Word." }
}

function Get-Bucket([string]$AwsProfile) {
    $id = Invoke-AwsJson $AwsProfile @('sts', 'get-caller-identity')
    "pulso-prod-buildbox-$($id.Account)"
}

function Get-Instance([string]$AwsProfile) {
    $found = Invoke-AwsJson $AwsProfile @('ec2', 'describe-instances',
        '--filters', 'Name=tag:Purpose,Values=buildbox', 'Name=instance-state-name,Values=pending,running,stopping,stopped',
        '--query', 'Reservations[].Instances[].{Id:InstanceId,State:State.Name,Launch:LaunchTime}')
    $list = @($found)
    if ($list.Count -eq 0 -or $null -eq $list[0]) {
        throw 'No buildbox instance found. The human must first run: terraform -chdir=terraform/envs/buildbox apply (admin profile); see docs/buildbox.md.'
    }
    $list[0]
}

function Wait-Ssm([string]$AwsProfile, [string]$InstanceId, [int]$MaxTries = 60) {
    for ($i = 0; $i -lt $MaxTries; $i++) {
        $info = Invoke-AwsJson $AwsProfile @('ssm', 'describe-instance-information',
            '--filters', "Key=InstanceIds,Values=$InstanceId", '--query', 'InstanceInformationList[].{PingStatus:PingStatus}')
        if (@($info) | Where-Object { $_.PingStatus -eq 'Online' }) { Write-Host "Instance $InstanceId is running and SSM online."; return }
        Start-Sleep -Seconds 5
    }
    throw "Instance $InstanceId did not become SSM online in time (first boot installs the toolchain: wait a few minutes, then retry up)."
}

function Publish-Runner([string]$AwsProfile, [string]$Bucket) {
    $runner = Join-Path $PSScriptRoot 'buildbox-runner.sh'
    Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('s3', 'cp', $runner, "s3://$Bucket/runner/buildbox-runner.sh", '--quiet') | Out-Null
}

function Send-RunShell {
    # Sends one AWS-RunShellScript command to this instance only; optionally waits for a terminal status.
    param([string]$AwsProfile, [string]$InstanceId, [string]$Line, [int]$TimeoutSeconds, [string]$Comment, [bool]$Wait)
    $params = @{ commands = @($Line); executionTimeout = @("$TimeoutSeconds") } | ConvertTo-Json -Compress
    $file = Join-Path (Get-WorkDir) "params-$([guid]::NewGuid().ToString('N').Substring(0, 8)).json"
    Set-Content -Path $file -Value $params -Encoding ascii
    try {
        $sent = Invoke-AwsJson $AwsProfile @('ssm', 'send-command', '--instance-ids', $InstanceId,
            '--document-name', 'AWS-RunShellScript', '--comment', $Comment, '--timeout-seconds', '60',
            '--parameters', ('file://' + ($file -replace '\\', '/')))
    }
    finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue }
    $cid = $sent.Command.CommandId
    Write-Host "SSM command id: $cid"
    if (-not $Wait) { return $cid }
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds + 120)
    while ((Get-Date) -lt $deadline) {
        $inv = Invoke-AwsJson $AwsProfile @('ssm', 'get-command-invocation', '--command-id', $cid, '--instance-id', $InstanceId)
        if ($inv.Status -in @('Success')) { Write-Host "Remote status: Success (exit $($inv.ResponseCode))."; return $cid }
        if ($inv.Status -in @('Failed', 'Cancelled', 'TimedOut', 'Cancelling')) {
            throw "Remote command ended with status $($inv.Status) (exit $($inv.ResponseCode)). Read the log: buildbox.ps1 logs -Lane <lane> -Id <id>"
        }
        Start-Sleep -Seconds 5
    }
    throw "Gave up waiting for command $cid. It may still be running: buildbox.ps1 logs, or status."
}

function Get-Uptime($inst) {
    try { [DateTime]::Parse($inst.Launch).ToUniversalTime() } catch { return $null }
}

function Invoke-Status([string]$AwsProfile) {
    $inst = Get-Instance $AwsProfile
    $bucket = Get-Bucket $AwsProfile
    Write-Host "Instance : $($inst.Id)"
    Write-Host "State    : $($inst.State)"
    if ($inst.State -eq 'running') {
        $launch = Get-Uptime $inst
        if ($launch) {
            $hours = [math]::Max(0, ((Get-Date).ToUniversalTime() - $launch).TotalHours)
            Write-Host ("Uptime   : {0:N1} h since the last start" -f $hours)
            Write-Host ("Cost     : about {0:N2} USD for this run (on-demand {1} USD/h, compute only)" -f ($hours * $script:HourlyUsd), $script:HourlyUsd)
        }
    }
    else {
        Write-Host "Cost     : stopped = disk only, about $($script:DiskMonthlyUsd) USD/month (no compute charge)"
    }
    $jobs = @(& aws s3 ls "s3://$bucket/state/running/" --recursive --profile $AwsProfile --region $script:Region | Where-Object { $_ })
    Write-Host "Running jobs: $($jobs.Count)"
    foreach ($j in $jobs) { Write-Host "  $(($j -replace '^.*state/running/', ''))" }
}

function Invoke-Sync([hashtable]$p, [string]$AwsProfile) {
    if (-not $p.Worktree -or -not (Test-Path -LiteralPath $p.Worktree -PathType Container)) { throw "Worktree '$($p.Worktree)' not found: pass -Worktree <existing directory>." }
    Assert-Lane $p.Lane
    $id = if ($p.Id) { $p.Id } else { '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 4)) }
    Assert-JobId $id
    $bucket = Get-Bucket $AwsProfile
    $key = "jobs/$($p.Lane)/$id.tar.gz"
    Write-Host 'Excluded from the archive (never uploaded):'
    foreach ($e in $script:Excludes) { Write-Host "  $e" }
    Write-Host '  (.git IS included; a linked worktree .git pointer file is replaced by a fresh repo on the box)'
    Confirm-Action "tar the worktree '$($p.Worktree)' and upload it to s3://$bucket/jobs/ as $key" $p.Yes
    $tarFile = Join-Path (Get-WorkDir) "$($p.Lane)-$id.tar.gz"
    try {
        $tarArgs = @('-czf', $tarFile)
        foreach ($e in $script:Excludes) { $tarArgs += "--exclude=$($e.TrimEnd('/'))" }
        $tarArgs += @('-C', $p.Worktree, '.')
        & tar @tarArgs
        if ($LASTEXITCODE -ne 0) { throw "tar failed (exit $LASTEXITCODE)." }
        Invoke-Aws -AwsProfile $AwsProfile -CliArgs @('s3', 'cp', $tarFile, "s3://$bucket/$key", '--quiet') | Out-Null
    }
    finally { Remove-Item -LiteralPath $tarFile -Force -ErrorAction SilentlyContinue }
    Set-Content -Path (Join-Path (Get-WorkDir) "last-$($p.Lane).id") -Value $id -Encoding ascii
    Write-Host "Uploaded. Job id: $id  (next: buildbox.ps1 run -Lane $($p.Lane) -Id $id -Cmd '<command>')"
}

function Invoke-Run([hashtable]$p, [string]$AwsProfile) {
    Assert-Lane $p.Lane
    if ([string]::IsNullOrWhiteSpace($p.Cmd)) { throw '-Cmd is required (the shell command to run on the box).' }
    $jobs = if ($p.Jobs) { [int]$p.Jobs } else { 2 }
    $timeout = if ($null -ne $p.Timeout) { [int]$p.Timeout } else { 60 }
    if ($jobs -lt 1 -or $jobs -gt 8) { throw '-Jobs must be between 1 and 8.' }
    if ($timeout -lt 1 -or $timeout -gt 240) { throw '-Timeout must be between 1 and 240 minutes.' }
    $id = $p.Id
    if (-not $id) {
        $f = Join-Path (Get-WorkDir) "last-$($p.Lane).id"
        if (-not (Test-Path $f)) { throw "No -Id given and no previous sync for lane $($p.Lane): run sync first." }
        $id = (Get-Content $f -Raw).Trim()
    }
    Assert-JobId $id
    $inst = Get-Instance $AwsProfile
    if ($inst.State -ne 'running') { throw "Instance is $($inst.State): run buildbox.ps1 up first." }
    $bucket = Get-Bucket $AwsProfile
    Confirm-Action "run on $($inst.Id) (lane $($p.Lane), job $id, jobs=$jobs, timeout=${timeout}m): $($p.Cmd)" $p.Yes
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($p.Cmd))
    $line = "aws s3 cp s3://$bucket/runner/buildbox-runner.sh /usr/local/bin/buildbox-runner.sh --quiet && sed -i 's/\r$//' /usr/local/bin/buildbox-runner.sh && bash /usr/local/bin/buildbox-runner.sh --bucket $bucket --lane $($p.Lane) --id $id --jobs $jobs --timeout $timeout --cmd-b64 $b64"
    Publish-Runner $AwsProfile $bucket
    Send-RunShell -AwsProfile $AwsProfile -InstanceId $inst.Id -Line $line -TimeoutSeconds ($timeout * 60 + 120) -Comment "buildbox:$($p.Lane):$id" -Wait (-not $p.NoWait) | Out-Null
    Write-Host "Results: s3://$bucket/out/$($p.Lane)/$id/  (buildbox.ps1 fetch -Lane $($p.Lane) -Id $id -Dest <dir>)"
}

function Invoke-Down([hashtable]$p) {
    if ([string]::IsNullOrWhiteSpace($p.AdminProfile)) { throw 'down needs -AdminProfile <the ADMIN profile>: the scoped pulso-buildbox user cannot destroy the stack.' }
    Assert-Profile $p.AdminProfile ($p.AllowAny -eq $true)
    $dir = Get-EnvDir
    Write-Host "This runs terraform destroy of terraform/envs/buildbox with AWS_PROFILE=$($p.AdminProfile): instance, volumes, bucket (force_destroy) and IAM user pulso-buildbox are removed."
    $env:AWS_PROFILE = $p.AdminProfile
    $env:AWS_REGION = $script:Region
    $env:AWS_DEFAULT_REGION = $script:Region
    if ($p.BackendConfig) {
        & terraform "-chdir=$dir" init -input=false -reconfigure "-backend-config=$($p.BackendConfig)"
    }
    else { & terraform "-chdir=$dir" init -input=false }
    if ($LASTEXITCODE -ne 0) { throw 'terraform init failed.' }
    $plan = Join-Path (Get-WorkDir) 'buildbox-destroy.tfplan'
    & terraform "-chdir=$dir" plan -destroy -input=false "-out=$plan"
    if ($LASTEXITCODE -ne 0) { throw 'terraform plan -destroy failed.' }
    $text = & terraform "-chdir=$dir" show -no-color $plan
    @($text | Where-Object { $_ -match '^\s*#\s' -or $_ -match '^(Plan:|No changes)' }) | ForEach-Object { Write-Host $_ }
    Read-TypedWord 'DESTROY'
    & terraform "-chdir=$dir" apply -input=false $plan
    if ($LASTEXITCODE -ne 0) { throw 'terraform apply (destroy plan) failed.' }
    Write-Host 'Destroyed. Check nothing is left: buildbox.ps1 verify-gone (any profile that may call the tagging API).'
}

function Invoke-VerifyGone([string]$AwsProfile) {
    $tagged = Invoke-AwsJson $AwsProfile @('resourcegroupstaggingapi', 'get-resources', '--tag-filters', 'Key=Purpose,Values=buildbox')
    $left = @($tagged.ResourceTagMappingList)
    $bucket = Get-Bucket $AwsProfile
    $bucketExists = $false
    $msg = & aws s3api head-bucket --bucket $bucket --profile $AwsProfile --region $script:Region 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { $bucketExists = $true }
    elseif ($msg -notmatch '404|Not Found|NoSuchBucket') { $bucketExists = $true; Write-Host "head-bucket was not a clean 404 (treated as still existing): $($msg.Trim())" }
    $problems = @()
    if ($left.Count -gt 0) { $problems += "$($left.Count) tagged resource(s) still exist: " + (($left | ForEach-Object { $_.ResourceARN }) -join ', ') }
    if ($bucketExists) { $problems += "bucket $bucket still exists" }
    if ($problems.Count -gt 0) { throw ($problems -join '; ') }
    Write-Host 'verify-gone: nothing left (no resource tagged Purpose=buildbox in us-east-1, bucket gone).'
}

function Invoke-Buildbox {
    [CmdletBinding()]
    param([string]$Command, [string]$Profile, [bool]$AllowAnyProfile = $false, [hashtable]$Options = @{})
    $p = @{} + $Options
    if (-not $Command) { throw 'Usage: buildbox.ps1 <up|stop|down|status|sync|run|logs|fetch|gc|verify-gone> [-Profile pulso-buildbox]' }
    if (-not $Profile) { $Profile = $script:DefaultProfile }
    $yes = [bool]$p.Yes

    if ($Command -eq 'down') { $p.AllowAny = $AllowAnyProfile; Invoke-Down $p; return }

    Assert-Profile $Profile $AllowAnyProfile
    $env:AWS_PROFILE = $Profile
    $env:AWS_REGION = $script:Region
    $env:AWS_DEFAULT_REGION = $script:Region

    switch ($Command) {
        'up' {
            $inst = Get-Instance $Profile
            $bucket = Get-Bucket $Profile
            Confirm-Action "start the buildbox $($inst.Id) (currently $($inst.State)); it bills about $($script:HourlyUsd) USD/h and stops itself after 30 idle minutes" $yes
            if ($inst.State -eq 'stopping') { throw 'Instance is stopping: wait a minute and retry up.' }
            if ($inst.State -eq 'stopped') { Invoke-Aws -AwsProfile $Profile -CliArgs @('ec2', 'start-instances', '--instance-ids', $inst.Id) | Out-Null }
            Wait-Ssm $Profile $inst.Id
            Publish-Runner $Profile $bucket
        }
        'stop' {
            $inst = Get-Instance $Profile
            Confirm-Action "stop the buildbox $($inst.Id) (running jobs are interrupted; disks are kept)" $yes
            Invoke-Aws -AwsProfile $Profile -CliArgs @('ec2', 'stop-instances', '--instance-ids', $inst.Id) | Out-Null
            Write-Host 'Stop requested.'
        }
        'status' { Invoke-Status $Profile }
        'sync' { $p.Yes = $yes; Invoke-Sync $p $Profile }
        'run' { $p.Yes = $yes; Invoke-Run $p $Profile }
        'logs' {
            Assert-Lane $p.Lane; Assert-JobId $p.Id
            $bucket = Get-Bucket $Profile
            Invoke-Aws -AwsProfile $Profile -CliArgs @('s3', 'cp', "s3://$bucket/out/$($p.Lane)/$($p.Id)/combined.log", '-') | ForEach-Object { Write-Host $_ }
        }
        'fetch' {
            Assert-Lane $p.Lane; Assert-JobId $p.Id
            if ([string]::IsNullOrWhiteSpace($p.Dest)) { throw 'fetch needs -Dest <directory>.' }
            New-Item -ItemType Directory -Force -Path $p.Dest | Out-Null
            $bucket = Get-Bucket $Profile
            Invoke-Aws -AwsProfile $Profile -CliArgs @('s3', 'cp', "s3://$bucket/out/$($p.Lane)/$($p.Id)/", $p.Dest, '--recursive') | ForEach-Object { Write-Host $_ }
        }
        'gc' {
            $inst = Get-Instance $Profile
            if ($inst.State -ne 'running') { throw "Instance is $($inst.State): run buildbox.ps1 up first." }
            $hours = if ($p.KeepHours) { [int]$p.KeepHours } else { 24 }
            $bucket = Get-Bucket $Profile
            Confirm-Action "delete work dirs older than $hours h under /work on $($inst.Id) (cargo registry and target caches are kept)" $yes
            Publish-Runner $Profile $bucket
            $line = "aws s3 cp s3://$bucket/runner/buildbox-runner.sh /usr/local/bin/buildbox-runner.sh --quiet && sed -i 's/\r$//' /usr/local/bin/buildbox-runner.sh && bash /usr/local/bin/buildbox-runner.sh gc --hours $hours"
            Send-RunShell -AwsProfile $Profile -InstanceId $inst.Id -Line $line -TimeoutSeconds 600 -Comment 'buildbox:gc' -Wait $true | Out-Null
        }
        'verify-gone' { Invoke-VerifyGone $Profile }
    }
}

if ($LibraryOnly) { return }

$options = @{
    AdminProfile = $AdminProfile; BackendConfig = $BackendConfig; Worktree = $Worktree; Lane = $Lane; Id = $Id; Cmd = $Cmd
    Jobs = $Jobs; Timeout = $Timeout; Dest = $Dest; KeepHours = $KeepHours; NoWait = [bool]$NoWait; Yes = [bool]$Yes
}
Invoke-Buildbox -Command $Command -Profile $Profile -AllowAnyProfile ([bool]$AllowAnyProfile) -Options $options


