# Pester (3.x style) tests for scripts/buildbox.ps1. Offline: a fake `aws` and a fake `terraform` are put first on PATH,
# so no real cloud call, credential or terraform process is ever involved.
$script:Target = Join-Path (Split-Path $PSScriptRoot -Parent) 'buildbox.ps1'
$script:Runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'buildbox-runner.sh'
. $script:Target -LibraryOnly

function New-FakeBin([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Set-Content -Encoding ascii (Join-Path $Dir 'aws.cmd') '@pwsh -NoProfile -File "%~dp0fake-aws.ps1" %*'
    Set-Content -Encoding ascii (Join-Path $Dir 'fake-aws.ps1') @'
$line = 'aws ' + ($args -join ' ')
Add-Content -Path $env:FAKE_LOG -Value $line
$a = $args -join ' '
if ($a -match '^sts get-caller-identity') { '{"UserId":"AIDAFAKE","Account":"000000000000","Arn":"arn:aws:iam::000000000000:user/pulso-buildbox"}'; exit 0 }
if ($a -match '^ec2 describe-instances') {
    switch ($env:FAKE_STATE) {
        'none' { '[]' }
        default { '[{"Id":"i-0fake","State":"' + $env:FAKE_STATE + '","Launch":"' + $env:FAKE_LAUNCH + '"}]' }
    }
    exit 0
}
if ($a -match '^ssm describe-instance-information') { if ($env:FAKE_SSM -eq 'offline') { '[]' } else { '[{"PingStatus":"Online"}]' }; exit 0 }
if ($a -match '^ssm send-command') {
    $i = [array]::IndexOf($args, '--parameters')
    $p = ($args[$i + 1]) -replace '^file://', ''
    Copy-Item $p $env:FAKE_PARAMS -Force
    '{"Command":{"CommandId":"cmd-123"}}'; exit 0
}
if ($a -match '^ssm get-command-invocation') { '{"Status":"' + $env:FAKE_INVOKE + '","ResponseCode":' + $env:FAKE_RC + '}'; exit 0 }
if ($a -match '^s3 ls') { if ($env:FAKE_JOBS) { $env:FAKE_JOBS }; exit 0 }
if ($a -match '^s3 cp ') {
    $src = $args[2]
    if ($src -and (Test-Path $src -PathType Leaf) -and $src -match '\.tar\.gz$') { Copy-Item $src $env:FAKE_UPLOAD -Force }
    if ($args[3] -eq '-') { 'LOG-LINE-FROM-S3' }
    exit 0
}
if ($a -match '^s3api head-bucket') {
    if ($env:FAKE_BUCKET -eq 'exists') { exit 0 }
    [Console]::Error.WriteLine('An error occurred (404) when calling the HeadBucket operation: Not Found'); exit 254
}
if ($a -match '^resourcegroupstaggingapi get-resources') {
    if ($env:FAKE_TAGGED -eq 'some') { '{"ResourceTagMappingList":[{"ResourceARN":"arn:aws:ec2:us-east-1:000000000000:instance/i-0fake"}]}' } else { '{"ResourceTagMappingList":[]}' }
    exit 0
}
exit 0
'@
    Set-Content -Encoding ascii (Join-Path $Dir 'terraform.cmd') @'
@echo off
echo terraform %* [AWS_PROFILE=%AWS_PROFILE%]>>"%FAKE_LOG%"
echo %* | findstr /c:" show " >nul && echo   # aws_instance.this will be destroyed
echo %* | findstr /c:" show " >nul && echo Plan: 0 to add, 0 to change, 9 to destroy.
exit /b 0
'@
}

function Use-Fakes([string]$State = 'running') {
    $script:Bin = Join-Path $TestDrive 'bin'
    New-FakeBin $script:Bin
    $script:OldPath = $env:PATH
    $script:OldProfile = $env:AWS_PROFILE
    $env:PATH = "$($script:Bin);$($env:PATH)"
    $env:FAKE_LOG = Join-Path $TestDrive 'calls.log'
    Remove-Item $env:FAKE_LOG -ErrorAction SilentlyContinue
    $env:FAKE_PARAMS = Join-Path $TestDrive 'params.json'
    $env:FAKE_UPLOAD = Join-Path $TestDrive 'upload.tar.gz'
    $env:FAKE_STATE = $State
    $env:FAKE_LAUNCH = (Get-Date).ToUniversalTime().AddHours(-2).ToString('yyyy-MM-ddTHH:mm:ss.000Z')
    $env:FAKE_INVOKE = 'Success'
    $env:FAKE_RC = '0'
    $env:FAKE_SSM = 'online'
    $env:FAKE_JOBS = ''
    $env:FAKE_BUCKET = 'gone'
    $env:FAKE_TAGGED = 'none'
    $env:BUILDBOX_WORKDIR = Join-Path $TestDrive 'work'
    New-Item -ItemType Directory -Force -Path $env:BUILDBOX_WORKDIR | Out-Null
}

function Restore-Fakes { $env:PATH = $script:OldPath; $env:AWS_PROFILE = $script:OldProfile }

function Get-Calls { if (Test-Path $env:FAKE_LOG) { Get-Content $env:FAKE_LOG -Raw } else { '' } }

function Run([string]$Command, [hashtable]$Options = @{}, [string]$Profile = 'pulso-buildbox', [bool]$AllowAny = $false) {
    & { Invoke-Buildbox -Command $Command -Profile $Profile -AllowAnyProfile $AllowAny -Options $Options } 6>&1 | Out-String
}

function New-Worktree {
    $wt = Join-Path $TestDrive 'wt'
    New-Item -ItemType Directory -Force -Path "$wt/src", "$wt/target/debug", "$wt/node_modules/x", "$wt/.terraform", "$wt/.git" | Out-Null
    Set-Content "$wt/src/main.rs" 'fn main(){}'
    Set-Content "$wt/.git/HEAD" 'ref: refs/heads/main'
    Set-Content "$wt/target/debug/big.bin" 'x'
    Set-Content "$wt/node_modules/x/i.js" 'x'
    Set-Content "$wt/.terraform/p" 'x'
    Set-Content "$wt/terraform.tfstate" 'x'
    Set-Content "$wt/terraform.tfstate.backup" 'x'
    Set-Content "$wt/.env" 'SECRET=1'
    Set-Content "$wt/key.pem" 'x'
    Set-Content "$wt/credentials.json" 'x'
    Set-Content "$wt/id_rsa" 'x'
    $wt
}

Describe 'Assert-Profile' {
    foreach ($bad in 'default', 'payana-prod', 'higo', 'standar-ai', 'management-root', 'Default') {
        It "refuses $bad" { { Assert-Profile $bad $false } | Should Throw 'Refusing profile' }
    }
    It 'refuses an empty profile' { { Assert-Profile '' $false } | Should Throw '-Profile' }
    It 'allows pulso-buildbox' { Assert-Profile 'pulso-buildbox' $false }
    It 'defaults to pulso-buildbox in us-east-1' {
        $script:DefaultProfile | Should Be 'pulso-buildbox'
        $script:Region | Should Be 'us-east-1'
    }
}

Describe 'Test-JobArgs' {
    It 'accepts a normal lane' { Assert-Lane 'infra-claude-1' }
    foreach ($bad in '', 'A b', '../x', 'x;rm', 'UP') {
        It "refuses lane '$bad'" { { Assert-Lane $bad } | Should Throw 'lane' }
    }
    It 'refuses a bad id' { { Assert-JobId 'a/b' } | Should Throw 'id' }
}

Describe 'up' {
    AfterEach { Restore-Fakes }

    It 'starts a stopped instance, waits for SSM online, then uploads the runner (in that order)' {
        Use-Fakes 'stopped'
        $out = Run 'up' @{ Yes = $true }
        $calls = Get-Calls
        $calls | Should Match 'ec2 start-instances --instance-ids i-0fake'
        $s = $calls.IndexOf('describe-instances'); $st = $calls.IndexOf('start-instances'); $w = $calls.IndexOf('ssm describe-instance-information'); $u = $calls.IndexOf('s3 cp')
        ($s -lt $st) | Should Be $true
        ($st -lt $w) | Should Be $true
        ($w -lt $u) | Should Be $true
        $calls | Should Match 'buildbox-runner.sh s3://pulso-prod-buildbox-000000000000/runner/buildbox-runner.sh'
        $out | Should Match 'SSM online'
    }
    It 'does not start a running instance' {
        Use-Fakes 'running'
        Run 'up' @{ Yes = $true } | Out-Null
        Get-Calls | Should Not Match 'start-instances'
    }
    It 'pins profile and region on every aws call' {
        Use-Fakes 'running'
        Run 'up' @{ Yes = $true } | Out-Null
        foreach ($l in (Get-Calls) -split "`r?`n" | Where-Object { $_ }) { $l | Should Match '--profile pulso-buildbox --region us-east-1' }
    }
    It 'tells the human to apply terraform when no instance exists' {
        Use-Fakes 'none'
        { Run 'up' @{ Yes = $true } } | Should Throw 'terraform'
    }
    It 'asks for confirmation and aborts without it' {
        Use-Fakes 'stopped'
        Mock Read-Host { 'no' }
        { Run 'up' @{} } | Should Throw 'Aborted'
        Get-Calls | Should Not Match 'start-instances'
    }
    It 'refuses a bad profile before any aws call' {
        Use-Fakes 'stopped'
        { Run 'up' @{ Yes = $true } 'standar-x' } | Should Throw 'Refusing profile'
        Get-Calls | Should Be ''
    }
}

Describe 'stop' {
    AfterEach { Restore-Fakes }
    It 'stops the instance after describing it' {
        Use-Fakes 'running'
        Run 'stop' @{ Yes = $true } | Out-Null
        $calls = Get-Calls
        $calls | Should Match 'ec2 stop-instances --instance-ids i-0fake'
        ($calls.IndexOf('describe-instances') -lt $calls.IndexOf('stop-instances')) | Should Be $true
    }
    It 'needs confirmation' {
        Use-Fakes 'running'
        Mock Read-Host { '' }
        { Run 'stop' @{} } | Should Throw 'Aborted'
        Get-Calls | Should Not Match 'stop-instances'
    }
}

Describe 'status' {
    AfterEach { Restore-Fakes }
    It 'prints state, uptime, running jobs and an estimated cost; changes nothing' {
        Use-Fakes 'running'
        $env:FAKE_JOBS = '2026-10-04 10:00:00          0 infra-a/20261004-abcd'
        $out = Run 'status' @{}
        $out | Should Match 'State\s+: running'
        $out | Should Match 'Uptime'
        $out | Should Match 'infra-a/20261004-abcd'
        $out | Should Match 'USD'
        Get-Calls | Should Not Match 'start-instances|stop-instances|send-command'
    }
    It 'reports a stopped instance with disk-only cost' {
        Use-Fakes 'stopped'
        (Run 'status' @{}) | Should Match 'State\s+: stopped'
    }
}

Describe 'sync' {
    AfterEach { Restore-Fakes }
    It 'uploads a tar.gz to jobs/<lane>/<id>.tar.gz and prints the exclusion list' {
        Use-Fakes 'running'
        $wt = New-Worktree
        $out = Run 'sync' @{ Worktree = $wt; Lane = 'lane-a'; Id = 'job1'; Yes = $true }
        Get-Calls | Should Match 's3 cp .*\.tar\.gz s3://pulso-prod-buildbox-000000000000/jobs/lane-a/job1\.tar\.gz'
        foreach ($x in 'target/', 'node_modules/', '.terraform/', '*.tfstate*', '.env', '*.pem') { $out | Should Match ([regex]::Escape($x)) }
        $out | Should Match 'job1'
    }
    It 'includes .git and sources but none of the excluded or credential-looking files' {
        Use-Fakes 'running'
        $wt = New-Worktree
        Run 'sync' @{ Worktree = $wt; Lane = 'lane-a'; Id = 'job2'; Yes = $true } | Out-Null
        $list = (& tar -tzf $env:FAKE_UPLOAD) -join "`n"
        $list | Should Match 'src/main.rs'
        $list | Should Match '\.git/HEAD'
        foreach ($bad in 'target/', 'node_modules', '\.terraform', 'tfstate', '\.env', 'key\.pem', 'credentials\.json', 'id_rsa') { $list | Should Not Match $bad }
    }
    It 'generates an id when none is given and remembers it for run' {
        Use-Fakes 'running'
        $wt = New-Worktree
        Run 'sync' @{ Worktree = $wt; Lane = 'lane-a'; Yes = $true } | Out-Null
        $id = (Get-Content (Join-Path $env:BUILDBOX_WORKDIR 'last-lane-a.id') -Raw).Trim()
        $id | Should Match '^\d{8}-\d{6}-[0-9a-f]{4}$'
    }
    It 'refuses a missing worktree or lane' {
        Use-Fakes 'running'
        { Run 'sync' @{ Worktree = (Join-Path $TestDrive 'nope'); Lane = 'x'; Yes = $true } } | Should Throw 'Worktree'
        { Run 'sync' @{ Worktree = (New-Worktree); Lane = ''; Yes = $true } } | Should Throw 'lane'
    }
}

Describe 'run' {
    AfterEach { Restore-Fakes }
    It 'sends AWS-RunShellScript only to the instance, with lane, id, jobs, timeout and the base64 command, then polls' {
        Use-Fakes 'running'
        Run 'run' @{ Lane = 'lane-a'; Id = 'job1'; Cmd = 'cargo test -j 2 --offline --no-fail-fast'; Jobs = 2; Timeout = 45; Yes = $true } | Out-Null
        $calls = Get-Calls
        $calls | Should Match 'ssm send-command --instance-ids i-0fake --document-name AWS-RunShellScript'
        $calls | Should Match 'ssm get-command-invocation --command-id cmd-123 --instance-id i-0fake'
        $json = Get-Content $env:FAKE_PARAMS -Raw | ConvertFrom-Json
        $cmd = $json.commands -join ' '
        $cmd | Should Match 'runner/buildbox-runner.sh'
        $cmd | Should Match '--lane lane-a'
        $cmd | Should Match '--id job1'
        $cmd | Should Match '--jobs 2'
        $cmd | Should Match '--timeout 45'
        $b64 = [regex]::Match($cmd, '--cmd-b64 (\S+)').Groups[1].Value
        [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) | Should Be 'cargo test -j 2 --offline --no-fail-fast'
        ($json.executionTimeout -join '') | Should Be '2820'
    }
    It 'uses the last synced id when -Id is omitted' {
        Use-Fakes 'running'
        Set-Content (Join-Path $env:BUILDBOX_WORKDIR 'last-lane-a.id') '20261004-101010-beef'
        Run 'run' @{ Lane = 'lane-a'; Cmd = 'true'; Yes = $true } | Out-Null
        (Get-Content $env:FAKE_PARAMS -Raw) | Should Match '--id 20261004-101010-beef'
    }
    It 'refuses when the instance is not running' {
        Use-Fakes 'stopped'
        { Run 'run' @{ Lane = 'a'; Id = 'j'; Cmd = 'true'; Yes = $true } } | Should Throw 'buildbox.ps1 up'
        Get-Calls | Should Not Match 'send-command'
    }
    It 'throws with the status when the remote command fails' {
        Use-Fakes 'running'
        $env:FAKE_INVOKE = 'Failed'; $env:FAKE_RC = '101'
        { Run 'run' @{ Lane = 'a'; Id = 'j'; Cmd = 'false'; Yes = $true } } | Should Throw 'Failed'
    }
    It 'validates lane, jobs, timeout and an empty command' {
        Use-Fakes 'running'
        { Run 'run' @{ Lane = 'bad lane'; Id = 'j'; Cmd = 'true'; Yes = $true } } | Should Throw 'lane'
        { Run 'run' @{ Lane = 'a'; Id = 'j'; Cmd = ''; Yes = $true } } | Should Throw 'Cmd'
        { Run 'run' @{ Lane = 'a'; Id = 'j'; Cmd = 'true'; Jobs = 99; Yes = $true } } | Should Throw 'Jobs'
        { Run 'run' @{ Lane = 'a'; Id = 'j'; Cmd = 'true'; Timeout = 0; Yes = $true } } | Should Throw 'Timeout'
    }
    It 'needs confirmation' {
        Use-Fakes 'running'
        Mock Read-Host { 'n' }
        { Run 'run' @{ Lane = 'a'; Id = 'j'; Cmd = 'true' } } | Should Throw 'Aborted'
        Get-Calls | Should Not Match 'send-command'
    }
}

Describe 'logs and fetch' {
    AfterEach { Restore-Fakes }
    It 'logs streams out/<lane>/<id>/combined.log' {
        Use-Fakes 'running'
        $out = Run 'logs' @{ Lane = 'lane-a'; Id = 'job1' }
        Get-Calls | Should Match 's3 cp s3://pulso-prod-buildbox-000000000000/out/lane-a/job1/combined.log -'
        $out | Should Match 'LOG-LINE-FROM-S3'
    }
    It 'fetch copies the whole out prefix to -Dest' {
        Use-Fakes 'running'
        $dest = Join-Path $TestDrive 'results'
        Run 'fetch' @{ Lane = 'lane-a'; Id = 'job1'; Dest = $dest } | Out-Null
        Get-Calls | Should Match 's3 cp s3://pulso-prod-buildbox-000000000000/out/lane-a/job1/ .*results --recursive'
    }
    It 'fetch needs -Dest' {
        Use-Fakes 'running'
        { Run 'fetch' @{ Lane = 'a'; Id = 'j' } } | Should Throw 'Dest'
    }
}

Describe 'gc' {
    AfterEach { Restore-Fakes }
    It 'sends the runner in gc mode with the retention' {
        Use-Fakes 'running'
        Run 'gc' @{ KeepHours = 12; Yes = $true } | Out-Null
        $cmd = (Get-Content $env:FAKE_PARAMS -Raw | ConvertFrom-Json).commands -join ' '
        $cmd | Should Match 'buildbox-runner.sh gc --hours 12'
    }
}

Describe 'verify-gone' {
    AfterEach { Restore-Fakes }
    It 'passes when nothing is tagged and the bucket is gone' {
        Use-Fakes 'none'
        $out = Run 'verify-gone' @{}
        $out | Should Match 'nothing left'
        Get-Calls | Should Match 'resourcegroupstaggingapi get-resources --tag-filters Key=Purpose,Values=buildbox'
        Get-Calls | Should Match 's3api head-bucket --bucket pulso-prod-buildbox-000000000000'
    }
    It 'fails when tagged resources remain' {
        Use-Fakes 'none'
        $env:FAKE_TAGGED = 'some'
        { Run 'verify-gone' @{} } | Should Throw 'still exist'
    }
    It 'fails when the bucket still exists' {
        Use-Fakes 'none'
        $env:FAKE_BUCKET = 'exists'
        { Run 'verify-gone' @{} } | Should Throw 'bucket'
    }
}

Describe 'down' {
    AfterEach { Restore-Fakes }
    It 'requires -AdminProfile' {
        Use-Fakes 'running'
        { Run 'down' @{} } | Should Throw 'AdminProfile'
        Get-Calls | Should Be ''
    }
    It 'refuses a forbidden admin profile name' {
        Use-Fakes 'running'
        { Run 'down' @{ AdminProfile = 'management-root' } } | Should Throw 'Refusing profile'
    }
    It 'does not destroy unless DESTROY is typed, even with -Yes' {
        Use-Fakes 'running'
        Mock Read-Host { 'yes' }
        { Run 'down' @{ AdminProfile = 'pulso-prod'; Yes = $true } } | Should Throw 'DESTROY'
        Get-Calls | Should Not Match 'apply'
    }
    It 'plans, shows, then applies the destroy plan with the admin profile passed explicitly' {
        Use-Fakes 'running'
        Mock Read-Host { 'DESTROY' }
        $out = Run 'down' @{ AdminProfile = 'pulso-prod' }
        $out | Should Match 'terraform destroy'
        $calls = Get-Calls
        $calls | Should Match 'terraform -chdir=.*envs[\\/]buildbox plan -destroy'
        $calls | Should Match 'AWS_PROFILE=pulso-prod'
        ($calls.IndexOf('plan -destroy') -lt $calls.IndexOf(' apply ')) | Should Be $true
        $calls | Should Not Match 'pulso-buildbox'
    }
}

Describe 'runner script' {
    $script:RunnerText = Get-Content $script:Runner -Raw
    It 'exists with the contract pieces' {
        $script:RunnerText | Should Match 'MAX_JOBS=3'
        $script:RunnerText | Should Match 'flock'
        $script:RunnerText | Should Match 'CARGO_TARGET_DIR=.{0,2}/work/target/'
        $script:RunnerText | Should Match 'WORK/\.jobs'
        $script:RunnerText | Should Match 'result\.json'
        $script:RunnerText | Should Match 'combined\.log'
        $script:RunnerText | Should Match 'exit-code'
        $script:RunnerText | Should Match 'rust-toolchain'
        $script:RunnerText | Should Match 'jobs/'
        $script:RunnerText | Should Match 'out/'
    }
    It 'has valid bash syntax' {
        $gitBash = 'C:\Program Files\Git\bin\bash.exe'
        if (-not (Test-Path $gitBash)) { return }
        & $gitBash -n $script:Runner
        $LASTEXITCODE | Should Be 0
    }
    It 'uses LF line endings' {
        ([IO.File]::ReadAllText($script:Runner)).Contains("`r") | Should Be $false
    }
}



