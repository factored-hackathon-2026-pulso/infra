# Pester (3.x style) tests for scripts/aws-prod.ps1. Offline: a fake `aws` and a fake `terraform` are put first on PATH,
# so no real cloud call, credential or terraform process is ever involved.
$script:Target = Join-Path (Split-Path $PSScriptRoot -Parent) 'aws-prod.ps1'
. $script:Target -LibraryOnly

function New-FakeBin([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    # Fake aws: logs every call; answers from $env:FAKE_RESP\<service>-<command>[.<n>].txt (n = call counter), optional
    # <service>-<command>.rc for the exit code. With no response file it prints the caller identity JSON.
    Set-Content -Encoding ascii (Join-Path $Dir 'aws.cmd') @'
@echo off
setlocal enabledelayedexpansion
echo aws %*>>"%FAKE_LOG%"
set "SUB=%~1-%~2"
set "RC=0"
if exist "%FAKE_RESP%\!SUB!.rc" set /p RC=<"%FAKE_RESP%\!SUB!.rc"
set "CNT=0"
if exist "%FAKE_RESP%\!SUB!.cnt" set /p CNT=<"%FAKE_RESP%\!SUB!.cnt"
set /a CNT+=1
echo !CNT!>"%FAKE_RESP%\!SUB!.cnt"
if exist "%FAKE_RESP%\!SUB!.!CNT!.txt" (
  type "%FAKE_RESP%\!SUB!.!CNT!.txt"
) else if exist "%FAKE_RESP%\!SUB!.txt" (
  type "%FAKE_RESP%\!SUB!.txt"
) else (
  echo {"UserId":"AIDAFAKE","Account":"%FAKE_ACCOUNT%","Arn":"%FAKE_ARN%"}
)
exit /b !RC!
'@
    Set-Content -Encoding ascii (Join-Path $Dir 'terraform.cmd') @'
@echo off
echo terraform %*>>"%FAKE_LOG%"
echo %* | findstr /c:" show " >nul && echo Plan: 3 to add, 0 to change, 0 to destroy.
exit /b 0
'@
}

function Use-Fakes([string]$Arn) {
    $script:Bin = Join-Path $TestDrive 'bin'
    New-FakeBin $script:Bin
    $script:OldPath = $env:PATH
    $env:PATH = "$($script:Bin);$($env:PATH)"
    $env:FAKE_LOG = Join-Path $TestDrive 'calls.log'
    Remove-Item $env:FAKE_LOG -ErrorAction SilentlyContinue
    $env:FAKE_ACCOUNT = '000000000000'
    $env:FAKE_ARN = $Arn
    $env:AWS_PROD_WORKDIR = Join-Path $TestDrive 'work'
    $env:FAKE_RESP = Join-Path $TestDrive 'resp'
    New-Item -ItemType Directory -Force -Path $env:FAKE_RESP | Out-Null
    Get-ChildItem $env:FAKE_RESP | Remove-Item -Force
    $env:AWS_PROD_BUILD_ID = 'b1'
    New-Item -ItemType Directory -Force -Path $env:AWS_PROD_WORKDIR | Out-Null
    $script:RootWarned = $false
}

function Restore-Fakes { $env:PATH = $script:OldPath }

function Set-Resp([string]$Sub, [string]$Text, [int]$N = 0) {
    $name = if ($N -gt 0) { "$Sub.$N.txt" } else { "$Sub.txt" }
    Set-Content -Encoding ascii (Join-Path $env:FAKE_RESP $name) $Text
}

function Set-Rc([string]$Sub, [int]$Rc) { Set-Content -Encoding ascii (Join-Path $env:FAKE_RESP "$Sub.rc") $Rc }

function Get-Calls { if (Test-Path $env:FAKE_LOG) { Get-Content $env:FAKE_LOG -Raw } else { '' } }

function Run([string]$Command, [string]$Profile = 'pulso-prod', [hashtable]$Options = @{}, [bool]$AllowAny = $false) {
    $script:RootWarned = $false
    & { Invoke-AwsProd -Command $Command -Profile $Profile -AllowAnyProfile $AllowAny -Options $Options } 6>&1 | Out-String
}

# Like Run, but a throw is caught inside the capture so the text printed before it is kept (plus the message).
function RunTry([string]$Command, [string]$Profile = 'pulso-prod', [hashtable]$Options = @{}) {
    $script:RootWarned = $false
    & { try { Invoke-AwsProd -Command $Command -Profile $Profile -AllowAnyProfile $false -Options $Options } catch { "THROWN: $($_.Exception.Message)" } } 6>&1 | Out-String
}

Describe 'Assert-Profile' {
    foreach ($bad in 'default', 'payana-prod', 'higo', 'standar-ai', 'management-root', 'Default') {
        It "refuses $bad" { { Assert-Profile $bad $false } | Should Throw 'Refusing profile' }
        It "allows $bad with -AllowAnyProfile" { Assert-Profile $bad $true }
    }
    It 'refuses an empty profile' { { Assert-Profile '' $false } | Should Throw '-Profile' }
    It 'allows pulso-prod' { Assert-Profile 'pulso-prod' $false }
}

Describe 'check' {
    AfterEach { Restore-Fakes }

    It 'warns once, with the 3 safety lines, when the caller is root, and does not block' {
        Use-Fakes 'arn:aws:iam::000000000000:root'
        $out = Run 'check'
        $out | Should Match 'ARN type\s+: root'
        $out | Should Match 'ROOT user'
        $out | Should Match 'Enable MFA on root'
        $out | Should Match 'aws configure --profile pulso-prod'
        $out | Should Match 'Delete the root access key'
        $out | Should Match 'Deactivate, then Delete'
        ([regex]::Matches($out, 'WARNING')).Count | Should Be 1
    }

    It 'prints no warning for an IAM user and names the type' {
        Use-Fakes 'arn:aws:iam::000000000000:user/pulso-admin'
        $out = Run 'check'
        $out | Should Match 'ARN type\s+: iam-user'
        $out | Should Match '000000000000'
        $out | Should Not Match 'WARNING'
    }

    It 'refuses a forbidden profile before any aws call' {
        Use-Fakes 'arn:aws:iam::000000000000:root'
        { Run 'check' 'standar-prod' } | Should Throw 'Refusing profile'
        Get-Calls | Should Not Match 'aws'
    }

    It 'accepts a forbidden profile name only with -AllowAnyProfile' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Run 'check' 'higo-sandbox' @{} $true | Should Match 'iam-user'
    }
}

Describe 'root-keys-reminder' {
    It 'prints the reminder without calling aws' {
        Use-Fakes 'arn:aws:iam::000000000000:root'
        try {
            $out = Run 'root-keys-reminder' ''
            $out | Should Match 'Enable MFA'
            $out | Should Match 'only in the console'
            Get-Calls | Should Not Match 'aws'
        } finally { Restore-Fakes }
    }
}

Describe 'apply guards' {
    AfterEach { Restore-Fakes }

    It 'bootstrap-apply refuses without a saved plan and never calls terraform apply' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'bootstrap-apply' } | Should Throw 'saved plan'
        Get-Calls | Should Not Match 'terraform .* apply'
    }

    It 'apply refuses without a saved plan' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'apply' } | Should Throw 'saved plan'
        Get-Calls | Should Not Match ' apply '
    }

    It 'destroy refuses without a saved destroy plan' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'destroy' } | Should Throw 'saved plan'
    }

    It 'prints the plan summary and aborts unless the exact word APPLY is typed' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-Content (Join-Path $env:AWS_PROD_WORKDIR 'bootstrap.tfplan') 'x'
        foreach ($wrong in 'yes', 'apply', '', 'DESTROY') {
            $script:Typed = $wrong
            Mock Read-Host { $script:Typed }
            { Run 'bootstrap-apply' } | Should Throw 'Aborted'
        }
        Get-Calls | Should Not Match 'terraform .* apply'
    }

    It 'applies the saved plan after APPLY is typed, shows the summary first, never auto-approves' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-Content (Join-Path $env:AWS_PROD_WORKDIR 'bootstrap.tfplan') 'x'
        Mock Read-Host { 'APPLY' }
        $out = Run 'bootstrap-apply'
        $out | Should Match 'Plan: 3 to add'
        $calls = Get-Calls
        $calls | Should Match 'apply -input=false .*bootstrap.tfplan'
        $calls | Should Not Match 'auto-approve'
    }

    It 'destroy needs the word DESTROY, not APPLY' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-Content (Join-Path $env:AWS_PROD_WORKDIR 'destroy.tfplan') 'x'
        Mock Read-Host { 'APPLY' }
        { Run 'destroy' } | Should Throw 'Aborted'
        Mock Read-Host { 'DESTROY' }
        Run 'destroy' | Should Match 'Plan: 3 to add'
        Get-Calls | Should Match 'apply -input=false .*destroy.tfplan'
    }

    It 'plan refuses a tfvars that still has placeholders' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $vf = Join-Path $TestDrive 'prod.tfvars'
        Set-Content $vf 'images = { core = { core = "<registry>/x@sha256:REPLACE_WITH_64_HEX_DIGEST" } }'
        { Run 'plan' 'pulso-prod' @{ VarFile = $vf } } | Should Throw 'placeholders'
        Get-Calls | Should Not Match ' plan '
    }

    It 'a root caller is warned briefly but proceeds without any extra flag' {
        Use-Fakes 'arn:aws:iam::000000000000:root'
        Set-Content (Join-Path $env:AWS_PROD_WORKDIR 'bootstrap.tfplan') 'x'
        Mock Read-Host { 'APPLY' }
        $out = Run 'bootstrap-apply'
        $out | Should Match 'root user'
        ([regex]::Matches($out, 'WARNING')).Count | Should Be 1
        Get-Calls | Should Match 'terraform .* apply'
    }
}

Describe 'upload and images argument guards' {
    AfterEach { Restore-Fakes }

    It 'upload needs an existing directory' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'upload' 'pulso-prod' @{ Path = (Join-Path $TestDrive 'nope'); Dataset = 'e0' } } | Should Throw '-Path'
    }

    It 'upload rejects a dataset name that could escape landing/' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $d = Join-Path $TestDrive 'data'; New-Item -ItemType Directory -Force -Path $d | Out-Null
        { Run 'upload' 'pulso-prod' @{ Path = $d; Dataset = '../lake' } } | Should Throw '-Dataset'
    }

    It 'images needs every source directory' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'images' 'pulso-prod' @{} } | Should Throw 'PulsoDir'
    }
}

Describe 'Set-ImagesInTfvars' {
    It 'rewrites only the images block and keeps the rest of the file' {
        $f = Join-Path $TestDrive 'p.tfvars'
        Set-Content $f "enable_waf = false`nimages = {`n  core = {}`n}`nprotect_data_volume = true`n"
        $d = 'sha256:' + ('a' * 64)
        $refs = @{}; foreach ($k in 'core', 'gateway', 'support_api', 'support_web', 'proxy', 'pulso') { $refs[$k] = "r/$k@$d" }
        Set-ImagesInTfvars $f $refs
        $t = Get-Content -Raw $f
        $t | Should Match 'enable_waf = false'
        $t | Should Match 'protect_data_volume = true'
        $t | Should Match 'gateway = "r/gateway@sha256:a{64}"'
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Cloud image builds (images -Service) and deploys (deploy): every call is a fake aws call.
# ---------------------------------------------------------------------------------------------------------------------
$script:D64 = 'sha256:' + ('a' * 64)
$script:OLD64 = 'sha256:' + ('0' * 64)
$script:Registry = '000000000000.dkr.ecr.us-east-1.amazonaws.com'

function New-SrcTree([string]$Root) {
    foreach ($d in '.git', 'node_modules\pkg', 'target\debug', 'src', 'api') { New-Item -ItemType Directory -Force -Path (Join-Path $Root $d) | Out-Null }
    $files = @{
        '.git\config' = 'x'; 'node_modules\pkg\index.js' = 'x'; 'target\debug\app' = 'x'; '.env' = 'SECRET=1'; '.env.local' = 'SECRET=2'
        '.env.example' = 'KEY='; 'server.pem' = 'x'; 'private.key' = 'x'; 'credentials.json' = 'x'; 'aws_credentials' = 'x'; 'id_rsa' = 'x'
        'terraform.tfstate' = 'x'; 'prod.tfvars' = 'x'; '.npmrc' = 'x'
        'src\main.rs' = 'fn main(){}'; 'Dockerfile' = 'FROM scratch'; 'README.md' = 'hi'; 'api\Dockerfile' = 'FROM scratch'
    }
    foreach ($k in $files.Keys) { Set-Content -Path (Join-Path $Root $k) -Value $files[$k] }
}

function Get-ZipEntries([string]$Zip) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($Zip)
    try { @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
}

Describe 'Resolve-Service' {
    It 'knows the six services and the aliases the teams use' {
        (Resolve-Service 'support-platform-api').Name | Should Be 'support-platform-api'
        (Resolve-Service 'agent-core').Name | Should Be 'core-runtime'
        (Resolve-Service 'engine').Name | Should Be 'pulso-engine'
        (Resolve-Service 'support-api').Key | Should Be 'support_api'
    }
    It 'maps each service to its workload and SSM key' {
        $s = Resolve-Service 'llm-gateway'
        $s.Workloads -join ',' | Should Be 'core'
        $s.Key | Should Be 'gateway'
        $s.Repository | Should Be 'pulso-prod/llm-gateway'
    }
    It 'caddy is shared: it deploys to platform and engine' {
        (Resolve-Service 'caddy').Workloads -join ',' | Should Be 'platform,engine'
    }
    It 'rejects an unknown service and lists the valid ones' {
        { Resolve-Service 'nope' } | Should Throw 'Unknown service'
        { Resolve-Service 'nope' } | Should Throw 'core-runtime'
    }
}

Describe 'Test-ExcludedPath and New-SourceZip' {
    It 'excludes secrets, VCS data and build output but keeps .env.example' {
        foreach ($p in '.git', 'node_modules', 'target', '.env', '.env.local', 'server.pem', 'private.key', 'credentials.json', 'aws_credentials', 'id_rsa', 'terraform.tfstate', 'prod.tfvars', '.npmrc') {
            Test-ExcludedPath $p | Should Be $true
        }
        foreach ($p in '.env.example', 'Dockerfile', 'main.rs', 'README.md') { Test-ExcludedPath $p | Should Be $false }
    }

    It 'zips only what is allowed, with forward slashes, and reports what it left out' {
        $src = Join-Path $TestDrive 'src1'; New-SrcTree $src
        $zip = Join-Path $TestDrive 'out.zip'
        $r = New-SourceZip -ZipPath $zip -Roots @(@{ Dir = $src; Prefix = '' })
        $entries = Get-ZipEntries $zip
        $entries -contains 'src/main.rs' | Should Be $true
        $entries -contains 'api/Dockerfile' | Should Be $true
        $entries -contains '.env.example' | Should Be $true
        ($entries | Where-Object { $_ -match '\\' }).Count | Should Be 0
        ($entries | Where-Object { $_ -match '(^|/)(\.git|node_modules|target)/|\.env$|\.env\.local|\.pem$|\.key$|credentials|id_rsa|\.tfstate|\.tfvars|\.npmrc' }).Count | Should Be 0
        ($r.Excluded -join ' ') | Should Match '\.git'
        ($r.Excluded -join ' ') | Should Match 'node_modules'
        ($r.Excluded -join ' ') | Should Match 'server\.pem'
        $r.Files | Should Be $entries.Count
    }

    It 'places a second root under its prefix (agent-core checkout)' {
        $a = Join-Path $TestDrive 'a'; New-SrcTree $a
        $b = Join-Path $TestDrive 'b'; New-SrcTree $b
        $zip = Join-Path $TestDrive 'two.zip'
        New-SourceZip -ZipPath $zip -Roots @(@{ Dir = $a; Prefix = '' }, @{ Dir = $b; Prefix = 'agent-core' }) | Out-Null
        $entries = Get-ZipEntries $zip
        $entries -contains 'agent-core/src/main.rs' | Should Be $true
        $entries -contains 'src/main.rs' | Should Be $true
        ($entries | Where-Object { $_ -match '^agent-core/\.env$' }).Count | Should Be 0
    }
}

Describe 'images -Service (cloud build)' {
    AfterEach { Restore-Fakes; $env:AWS_PROD_BUILD_ID = $null }

    function Set-BuildOk([string]$Svc = 'support-platform-api') {
        Set-Resp 'codebuild-start-build' "pulso-prod-build-${Svc}:11111111-2222-3333-4444-555555555555"
        Set-Resp 'codebuild-batch-get-builds' 'IN_PROGRESS' 1
        Set-Resp 'codebuild-batch-get-builds' 'SUCCEEDED' 2
        Set-Resp 's3-cp' '' 1
        Set-Resp 's3-cp' ('{"image":"' + $script:Registry + '/pulso-prod/' + $Svc + '@' + $script:D64 + '","digest":"' + $script:D64 + '"}') 2
    }

    It 'needs -SourceDir, an existing directory' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api' } } | Should Throw '-SourceDir'
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = (Join-Path $TestDrive 'nope') } } | Should Throw '-SourceDir'
    }

    It 'core-runtime needs -AgentCoreDir and caddy needs -MirrorImage' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        { Run 'images' 'pulso-prod' @{ Service = 'agent-core'; SourceDir = $src; Yes = $true } } | Should Throw '-AgentCoreDir'
        { Run 'images' 'pulso-prod' @{ Service = 'caddy'; Yes = $true } } | Should Throw '-MirrorImage'
    }

    It 'rejects an unknown service before any aws call except the identity check' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'images' 'pulso-prod' @{ Service = 'nope'; SourceDir = $TestDrive } } | Should Throw 'Unknown service'
        Get-Calls | Should Not Match 's3 cp'
    }

    It 'prints the plan and the excluded files, and aborts unless DEPLOY is typed' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        foreach ($wrong in 'yes', 'APPLY', 'deploy', '') {
            $script:Typed = $wrong
            Mock Read-Host { $script:Typed }
            { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src } } | Should Throw 'Aborted'
        }
        $calls = Get-Calls
        $calls | Should Not Match 's3 cp'
        $calls | Should Not Match 'codebuild'
    }

    It 'shows what it will do and what it excluded before asking' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        Mock Read-Host { 'nope' }
        $out = RunTry 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src }
        $out | Should Match 'Excluded'
        $out | Should Match 'server\.pem'
        $out | Should Match 'pulso-prod-data-000000000000'
        $out | Should Match 'engine/build-src/support-platform-api/b1\.zip'
        $out | Should Match 'pulso-prod-build-support-platform-api'
        $out | Should Match 'THROWN: Aborted'
    }

    It 'uploads the zip, starts the build, waits, reads the record and prints repo@sha256' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-BuildOk
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        $vf = Join-Path $TestDrive 'prod.tfvars'
        $out = Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Yes = $true; VarFile = $vf }
        $out | Should Match ([regex]::Escape("$($script:Registry)/pulso-prod/support-platform-api@$($script:D64)"))
        $calls = Get-Calls
        $iUp = $calls.IndexOf('s3 cp')
        $iStart = $calls.IndexOf('codebuild start-build')
        $iWait = $calls.IndexOf('codebuild batch-get-builds')
        $iRec = $calls.IndexOf('engine/build-out/support-platform-api/b1.json')
        ($iUp -ge 0) | Should Be $true
        ($iUp -lt $iStart) | Should Be $true
        ($iStart -lt $iWait) | Should Be $true
        ($iWait -lt $iRec) | Should Be $true
        $calls | Should Match 's3://pulso-prod-data-000000000000/engine/build-src/support-platform-api/b1\.zip'
        $calls | Should Match '--project-name pulso-prod-build-support-platform-api'
        $calls | Should Match '--source-location-override pulso-prod-data-000000000000/engine/build-src/support-platform-api/b1\.zip'
        $calls | Should Match 'name=SOURCE_ID,value=b1'
        $calls | Should Not Match '--sse'
    }

    It 'records the image in prod.tfvars (uncommitted) and in the state file, leaving the other entries alone' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-BuildOk
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        $vf = Join-Path $TestDrive 'prod.tfvars'
        Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Yes = $true; VarFile = $vf } | Out-Null
        $t = Get-Content -Raw $vf
        $t | Should Match ('support_api = "' + [regex]::Escape($script:Registry) + '/pulso-prod/support-platform-api@' + $script:D64 + '"')
        $t | Should Match 'REPLACE_WITH_64_HEX_DIGEST'
        $state = Get-Content -Raw (Join-Path $env:AWS_PROD_WORKDIR 'images-state.json') | ConvertFrom-Json
        $state.'support-platform-api'.digest | Should Be $script:D64
        $state.'support-platform-api'.build_id | Should Be 'b1'
    }

    It 'a failed build throws with the status and leaves tfvars untouched' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-Resp 'codebuild-start-build' 'pulso-prod-build-support-platform-api:1111'
        Set-Resp 'codebuild-batch-get-builds' 'FAILED'
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        $vf = Join-Path $TestDrive 'prod.tfvars'; Set-Content $vf 'x = 1'
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Yes = $true; VarFile = $vf } } | Should Throw 'FAILED'
        (Get-Content -Raw $vf).Trim() | Should Be 'x = 1'
    }

    It 'refuses a build record whose image is not in the expected repository' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-BuildOk
        Set-Resp 's3-cp' ('{"image":"evil.example.com/other@' + $script:D64 + '","digest":"' + $script:D64 + '"}') 2
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } } | Should Throw 'unexpected'
    }

    It 'core-runtime is agent-core alone at the zip root, with its own Dockerfile and the pinned commit as GIT_SHA' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-BuildOk 'core-runtime'
        $core = Join-Path $TestDrive 'core'; New-SrcTree $core
        $sha = 'a' * 40
        Run 'images' 'pulso-prod' @{ Service = 'agent-core'; AgentCoreDir = $core; AgentCoreCommit = $sha; BuildArg = @('A=1'); Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } | Out-Null
        $entries = Get-ZipEntries (Join-Path $env:AWS_PROD_WORKDIR 'build-src-b1.zip')
        $entries -contains 'src/main.rs' | Should Be $true
        $entries -contains 'Dockerfile' | Should Be $true
        ($entries | Where-Object { $_ -like 'agent-core/*' -or $_ -like 'core-bridge/*' }).Count | Should Be 0
        ($entries | Where-Object { $_ -match '^\.env$' }).Count | Should Be 0
        $calls = Get-Calls
        $calls | Should Match "name=BUILD_ARGS,value=A=1 GIT_SHA=$sha"
        $calls | Should Match '--project-name pulso-prod-build-core-runtime'
    }

    It 'core-runtime refuses an engine -SourceDir, a malformed commit and a directory without git metadata and commit' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $src = Join-Path $TestDrive 'engine'; New-SrcTree $src
        $core = Join-Path $TestDrive 'core'; New-SrcTree $core
        { Run 'images' 'pulso-prod' @{ Service = 'agent-core'; SourceDir = $src; AgentCoreDir = $core; AgentCoreCommit = ('a' * 40); Yes = $true } } | Should Throw 'agent-core alone'
        { Run 'images' 'pulso-prod' @{ Service = 'agent-core'; AgentCoreDir = $core; AgentCoreCommit = 'main'; Yes = $true } } | Should Throw '40 hex'
        { Run 'images' 'pulso-prod' @{ Service = 'agent-core'; AgentCoreDir = $core; Yes = $true } } | Should Throw '-AgentCoreCommit'
    }

    It 'support-platform-web carries VITE_API_URL as a build arg' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-BuildOk 'support-platform-web'
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        Run 'images' 'pulso-prod' @{ Service = 'support-platform-web'; SourceDir = $src; BuildArg = @('VITE_API_URL=https://x.example'); Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } | Out-Null
        Get-Calls | Should Match 'name=BUILD_ARGS,value=VITE_API_URL=https://x\.example'
    }

    It 'caddy is mirrored: no zip, MIRROR_IMAGE passed, digest recorded' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-BuildOk 'caddy'
        Set-Resp 's3-cp' ('{"image":"' + $script:Registry + '/pulso-prod/caddy@' + $script:D64 + '","digest":"' + $script:D64 + '"}') 1
        $out = Run 'images' 'pulso-prod' @{ Service = 'caddy'; MirrorImage = 'docker.io/library/caddy:2.8.4-alpine'; Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') }
        $calls = Get-Calls
        $calls | Should Not Match 'build-src'
        $calls | Should Match 'name=MIRROR_IMAGE,value=docker\.io/library/caddy:2\.8\.4-alpine'
        $out | Should Match 'pulso-prod/caddy@sha256'
    }
}

Describe 'images -Service -Builder host (free_plan fallback: build on the core host)' {
    AfterEach { Restore-Fakes; $env:AWS_PROD_BUILD_ID = $null }

    function Set-HostBuildOk([string]$Svc = 'support-platform-api') {
        Set-Resp 'ec2-describe-instances' 'i-0123456789abcdef0'
        Set-Resp 'ssm-send-command' 'cmd-0001'
        Set-Resp 'ssm-list-command-invocations' 'i-0123456789abcdef0 InProgress' 1
        Set-Resp 'ssm-list-command-invocations' 'i-0123456789abcdef0 Success' 2
        Set-Resp 'ssm-get-command-invocation' 'IMAGE=built'
        Set-Resp 's3-cp' '' 1
        Set-Resp 's3-cp' ('{"image":"' + $script:Registry + '/pulso-prod/' + $Svc + '@' + $script:D64 + '","digest":"' + $script:D64 + '"}') 2
    }

    function Get-HostScript { (Get-Content -Raw (Join-Path $env:AWS_PROD_WORKDIR 'host-build-b1.json')) }

    It 'rejects an unknown builder' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Builder = 'laptop'; Yes = $true } } | Should Throw 'Builder'
    }

    It 'uploads the zip, finds the running core instance, builds through SSM and never starts CodeBuild' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-HostBuildOk
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        $vf = Join-Path $TestDrive 'prod.tfvars'
        $out = Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Builder = 'host'; Yes = $true; VarFile = $vf }
        $calls = Get-Calls
        $calls | Should Not Match 'codebuild'
        $calls | Should Match 'ec2 describe-instances'
        $calls | Should Match 'Name=tag:Workload,Values=core'
        $calls | Should Match 'Name=instance-state-name,Values=running'
        $calls | Should Match 'ssm send-command --instance-ids i-0123456789abcdef0 --document-name AWS-RunShellScript'
        $iUp = $calls.IndexOf('s3 cp')
        $iSend = $calls.IndexOf('ssm send-command')
        $iRec = $calls.IndexOf('engine/build-out/support-platform-api/b1.json')
        ($iUp -ge 0 -and $iUp -lt $iSend -and $iSend -lt $iRec) | Should Be $true
        $out | Should Match ([regex]::Escape("$($script:Registry)/pulso-prod/support-platform-api@$($script:D64)"))
        $out | Should Match 'core host'
    }

    It 'the host script pulls the zip from S3, builds in the service context with buildx and pushes to ECR' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-HostBuildOk
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Builder = 'host'; Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } | Out-Null
        $s = Get-HostScript
        $s | Should Match 's3://pulso-prod-data-000000000000/engine/build-src/support-platform-api/b1\.zip'
        $s | Should Match 'docker buildx build'
        $s | Should Match 'backend/Dockerfile'
        $s | Should Match 'src/backend'
        $s | Should Match 'ecr get-login-password'
        $s | Should Match 'docker push'
        $s | Should Match 'ecr describe-images'
        $s | Should Match 's3://pulso-prod-data-000000000000/engine/build-out/support-platform-api/b1\.json'
        $s | Should Match 'swap'
        (Get-Calls) | Should Match '--parameters file://'
    }

    It 'core-runtime builds agent-core with its own Dockerfile at the root context and no named build context' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-HostBuildOk 'core-runtime'
        $core = Join-Path $TestDrive 'core'; New-SrcTree $core
        $sha = 'b' * 40
        Run 'images' 'pulso-prod' @{ Service = 'agent-core'; AgentCoreDir = $core; AgentCoreCommit = $sha; Builder = 'host'; BuildArg = @('A=1'); Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } | Out-Null
        $s = Get-HostScript
        $s | Should Not Match '--build-context'
        $s | Should Match 'src/Dockerfile'
        $s | Should Match '--build-arg'
        $s | Should Match 'A=1'
        $s | Should Match "GIT_SHA=$sha"
    }

    It 'a build argument is quoted so it cannot inject shell into the root script' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-HostBuildOk
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Builder = 'host'; BuildArg = @('K=$(id)'); Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } | Out-Null
        (Get-HostScript) | Should Match "'K=\`$\(id\)'"
    }

    It 'caddy is mirrored on the host: pull, tag, push, record' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-HostBuildOk 'caddy'
        Set-Resp 's3-cp' ('{"image":"' + $script:Registry + '/pulso-prod/caddy@' + $script:D64 + '","digest":"' + $script:D64 + '"}') 1
        Run 'images' 'pulso-prod' @{ Service = 'caddy'; MirrorImage = 'docker.io/library/caddy:2.8.4-alpine'; Builder = 'host'; Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } | Out-Null
        $s = Get-HostScript
        $s | Should Match 'docker pull'
        $s | Should Match 'caddy:2\.8\.4-alpine'
        $s | Should Not Match 'buildx build'
        (Get-Calls) | Should Not Match 'build-src'
    }

    It 'fails clearly when no core instance is running' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-Resp 'ec2-describe-instances' ''
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Builder = 'host'; Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } } | Should Throw 'running core'
        (Get-Calls) | Should Not Match 'ssm send-command'
    }

    It 'a failed command throws with the command id and leaves tfvars untouched' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-Resp 'ec2-describe-instances' 'i-0123456789abcdef0'
        Set-Resp 'ssm-send-command' 'cmd-0002'
        Set-Resp 'ssm-list-command-invocations' 'i-0123456789abcdef0 Failed'
        Set-Resp 'ssm-get-command-invocation' 'Killed'
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        $vf = Join-Path $TestDrive 'hostfail.tfvars'
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; Builder = 'host'; Yes = $true; VarFile = $vf } } | Should Throw 'cmd-0002'
        (Test-Path $vf) | Should Be $false
    }
}

Describe 'plan -Stage builder' {
    AfterEach { Restore-Fakes }

    It 'plans only the builder (and what it needs) with throw-away digests, so the images can be built before the hosts exist' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $out = Run 'plan' 'pulso-prod' @{ Stage = 'builder'; VarFile = (Join-Path $TestDrive 'missing.tfvars') }
        $calls = Get-Calls
        $calls | Should Match 'terraform .* plan .*-target=module\.image_builder'
        $calls | Should Match 'builder-stage\.tfvars'
        $stage = Get-Content -Raw (Join-Path $env:AWS_PROD_WORKDIR 'builder-stage.tfvars')
        $stage | Should Match 'sha256:0{64}'
        $stage | Should Not Match 'REPLACE_WITH'
    }
}

Describe 'deploy' {
    AfterEach { Restore-Fakes }

    function Set-DeployOk([string]$Result = 'ok', [string]$Status = 'Success') {
        Set-Resp 'ecr-describe-images' $script:D64
        Set-Resp 'ssm-get-parameter' ($script:Registry + '/pulso-prod/support-platform-api@' + $script:OLD64)
        Set-Resp 'ssm-send-command' 'cmd-1'
        Set-Resp 'ssm-list-command-invocations' "i-0abc`t$Status"
        Set-Resp 'ssm-get-command-invocation' "DEPLOYED SUPPORT_API_IMAGE=x`nDEPLOY_RESULT=$Result"
    }

    It 'needs exactly one of -Digest, -FromBuild or -Rollback' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api' } } | Should Throw '-Digest'
        { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = $script:D64; FromBuild = 'b1' } } | Should Throw 'only one'
    }

    It 'needs -Service and a well-formed digest' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'deploy' 'pulso-prod' @{ Digest = $script:D64 } } | Should Throw '-Service'
        { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = 'latest' } } | Should Throw 'sha256'
        { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = 'sha256:abc' } } | Should Throw 'sha256'
    }

    It 'refuses a digest that is not in ECR and changes nothing' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-Rc 'ecr-describe-images' 254
        { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = $script:D64; Yes = $true } } | Should Throw 'not found in ECR'
        $calls = Get-Calls
        $calls | Should Not Match 'put-parameter'
        $calls | Should Not Match 'send-command'
    }

    It 'prints what it will do and aborts unless DEPLOY is typed' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-DeployOk
        foreach ($wrong in 'yes', 'APPLY', 'deploy', '') {
            $script:Typed = $wrong
            Mock Read-Host { $script:Typed }
            { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = $script:D64 } } | Should Throw 'Aborted'
        }
        $calls = Get-Calls
        $calls | Should Not Match 'put-parameter'
        $calls | Should Not Match 'send-command'
    }

    It 'prints the exact steps before asking' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-DeployOk
        Mock Read-Host { 'nope' }
        $out = RunTry 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = $script:D64 }
        $out | Should Match '/pulso/platform/images/support_api'
        $out | Should Match 'pulso-deploy-platform'
        $out | Should Match ([regex]::Escape($script:OLD64))
        $out | Should Match 'THROWN: Aborted'
    }

    It 'verifies in ECR, reads the old value, writes the parameter, sends the command, then reads the result, in that order' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-DeployOk
        $out = Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = $script:D64; Wait = $true; Yes = $true }
        $calls = Get-Calls
        $order = 'sts get-caller-identity', 'ecr describe-images', 'ssm get-parameter ', 'ssm put-parameter', 'ssm send-command', 'ssm list-command-invocations', 'ssm get-command-invocation'
        $last = -1
        foreach ($c in $order) {
            $i = $calls.IndexOf($c)
            ($i -gt $last) | Should Be $true
            $last = $i
        }
        $calls | Should Match '--name /pulso/platform/images/support_api'
        $calls | Should Match ('--value ' + [regex]::Escape("$($script:Registry)/pulso-prod/support-platform-api@$($script:D64)"))
        $calls | Should Match '--overwrite'
        $calls | Should Match '--document-name pulso-deploy-platform'
        $calls | Should Match '--targets Key=tag:Workload,Values=platform'
        $calls | Should Match '--repository-name pulso-prod/support-platform-api'
        $calls | Should Match ('imageDigest=' + $script:D64)
        $out | Should Match 'DEPLOY_RESULT=ok'
        $out | Should Match 'i-0abc'
    }

    It 'without -Wait it returns after sending the command and prints how to read the result' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-DeployOk
        $out = Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = $script:D64; Yes = $true }
        $calls = Get-Calls
        $calls | Should Match 'send-command'
        $calls | Should Not Match 'get-command-invocation'
        $out | Should Match 'cmd-1'
    }

    It 'a host that rolled back fails the deploy and restores the previous digest in SSM' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-DeployOk 'rolled_back' 'Failed'
        { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = $script:D64; Wait = $true; Yes = $true } } | Should Throw 'rolled back'
        $puts = @((Get-Calls) -split "`n" | Where-Object { $_ -match 'ssm put-parameter' })
        $puts.Count | Should Be 2
        $puts[0] | Should Match $script:D64
        $puts[1] | Should Match $script:OLD64
    }

    It 'a successful run that did not report DEPLOY_RESULT=ok is a failure' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-DeployOk 'failed' 'Success'
        { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Digest = $script:D64; Wait = $true; Yes = $true } } | Should Throw 'did not report'
    }

    It '-FromBuild reads the build record for that service and id' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-DeployOk
        Set-Resp 's3-cp' ('{"image":"' + $script:Registry + '/pulso-prod/support-platform-api@' + $script:D64 + '","digest":"' + $script:D64 + '"}')
        Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; FromBuild = 'b7'; Yes = $true } | Out-Null
        $calls = Get-Calls
        $calls | Should Match 's3://pulso-prod-data-000000000000/engine/build-out/support-platform-api/b7\.json'
        $calls | Should Match ('--value ' + [regex]::Escape("$($script:Registry)/pulso-prod/support-platform-api@$($script:D64)"))
    }

    It '-Rollback puts back the previous value from the parameter history' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-DeployOk
        $cur = "$($script:Registry)/pulso-prod/support-platform-api@$($script:D64)"
        $prev = "$($script:Registry)/pulso-prod/support-platform-api@$($script:OLD64)"
        Set-Resp 'ssm-get-parameter' $cur
        Set-Resp 'ssm-get-parameter-history' ('["' + $prev + '","' + $cur + '"]')
        Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Rollback = $true; Wait = $true; Yes = $true } | Out-Null
        $calls = Get-Calls
        $calls | Should Match 'ssm get-parameter-history --name /pulso/platform/images/support_api'
        $calls | Should Match ('--value ' + [regex]::Escape($prev))
        $calls | Should Match ('imageDigest=' + $script:OLD64)
    }

    It '-Rollback with no earlier value says so and changes nothing' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-DeployOk
        $cur = "$($script:Registry)/pulso-prod/support-platform-api@$($script:D64)"
        Set-Resp 'ssm-get-parameter' $cur
        Set-Resp 'ssm-get-parameter-history' ('["' + $cur + '"]')
        { Run 'deploy' 'pulso-prod' @{ Service = 'support-platform-api'; Rollback = $true; Yes = $true } } | Should Throw 'no previous'
        Get-Calls | Should Not Match 'put-parameter'
    }

    It 'caddy is shared: both the platform and the engine parameter are written and both documents run' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-DeployOk
        Run 'deploy' 'pulso-prod' @{ Service = 'caddy'; Digest = $script:D64; Yes = $true } | Out-Null
        $calls = Get-Calls
        $calls | Should Match '--name /pulso/platform/images/proxy'
        $calls | Should Match '--name /pulso/engine/images/proxy'
        $calls | Should Match 'pulso-deploy-platform'
        $calls | Should Match 'pulso-deploy-engine'
    }

    It 'a forbidden profile is refused before any aws call' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'deploy' 'standar-prod' @{ Service = 'support-platform-api'; Digest = $script:D64; Yes = $true } } | Should Throw 'Refusing profile'
        Get-Calls | Should Not Match 'aws'
    }
}

Describe 'staged build contexts and VITE_API_URL' {
    AfterEach { Restore-Fakes; $env:AWS_PROD_BUILD_ID = $null }

    It 'the backend state key is pulso/prod/hackathon/terraform.tfstate' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $file = Write-BackendHcl '000000000000'
        $text = Get-Content -Raw $file
        $text | Should Match 'key\s+= "pulso/prod/hackathon/terraform\.tfstate"'
        $text | Should Not Match 'pulso/prod/terraform'
        Restore-Fakes
    }

    It 'maps support-platform to backend/ and frontend/, core-runtime to agent-core own Dockerfile at the root' {
        $script:HostBuild['support-platform-api'].Context | Should Be 'backend'
        $script:HostBuild['support-platform-api'].Dockerfile | Should Be 'backend/Dockerfile'
        $script:HostBuild['support-platform-web'].Context | Should Be 'frontend'
        $script:HostBuild['support-platform-web'].Dockerfile | Should Be 'frontend/Dockerfile'
        $script:HostBuild['core-runtime'].Context | Should Be '.'
        $script:HostBuild['core-runtime'].Dockerfile | Should Be 'Dockerfile'
        $script:HostBuild['core-runtime'].CoreContext | Should Be ''
    }

    It 'the staged agent-core .dockerignore no longer excludes contracts, and keeps its other lines' {
        $core = Join-Path $TestDrive 'ac'; New-Item -ItemType Directory -Force -Path (Join-Path $core 'contracts') | Out-Null
        Set-Content (Join-Path $core 'contracts\VERSION') '1.3.0'
        Set-Content (Join-Path $core '.dockerignore') "tests`ncontracts`n/contracts/`ncontracts/`n.venv`n"
        $zip = Join-Path $TestDrive 'ac.zip'
        New-SourceZip -ZipPath $zip -Roots @(@{ Dir = $core; Prefix = 'agent-core'; AllowInDockerignore = @('contracts') }) | Out-Null
        (Get-ZipEntries $zip) -contains 'agent-core/contracts/VERSION' | Should Be $true
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try { $r = New-Object IO.StreamReader(($z.GetEntry('agent-core/.dockerignore')).Open()); $di = $r.ReadToEnd(); $r.Dispose() } finally { $z.Dispose() }
        $di | Should Not Match '(?m)^\s*/?contracts/?\s*$'
        $di | Should Match '(?m)^tests\s*$'
        $di | Should Match '(?m)^\.venv\s*$'
    }

    It 'Resolve-AgentCoreCommit: explicit commit without git metadata, a bad commit and a missing commit' {
        $dir = Join-Path $TestDrive 'nogit'; New-Item -ItemType Directory -Force -Path $dir | Out-Null
        Resolve-AgentCoreCommit $dir ('c' * 40) | Should Be ('c' * 40)
        { Resolve-AgentCoreCommit $dir 'abc' } | Should Throw '40 hex'
        { Resolve-AgentCoreCommit $dir '' } | Should Throw '-AgentCoreCommit'
    }

    It '-ViteApiUrl becomes the VITE_API_URL build arg of the web image only' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Mock Start-Sleep {}
        Set-Resp 'codebuild-start-build' 'pulso-prod-build-support-platform-web:11111111-2222-3333-4444-555555555555'
        Set-Resp 'codebuild-batch-get-builds' 'SUCCEEDED'
        Set-Resp 's3-cp' '' 1
        Set-Resp 's3-cp' ('{"image":"' + $script:Registry + '/pulso-prod/support-platform-web@' + $script:D64 + '","digest":"' + $script:D64 + '"}') 2
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        Run 'images' 'pulso-prod' @{ Service = 'support-platform-web'; SourceDir = $src; ViteApiUrl = 'https://d111.cloudfront.net'; Yes = $true; VarFile = (Join-Path $TestDrive 'p.tfvars') } | Out-Null
        Get-Calls | Should Match 'name=BUILD_ARGS,value=VITE_API_URL=https://d111\.cloudfront\.net'
    }

    It '-ViteApiUrl is refused for other services and for a malformed URL' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $src = Join-Path $TestDrive 'src'; New-SrcTree $src
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-api'; SourceDir = $src; ViteApiUrl = 'https://x.example'; Yes = $true } } | Should Throw 'ViteApiUrl'
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-web'; SourceDir = $src; ViteApiUrl = 'javascript:alert(1)'; Yes = $true } } | Should Throw 'ViteApiUrl'
        { Run 'images' 'pulso-prod' @{ Service = 'support-platform-web'; SourceDir = $src; ViteApiUrl = 'https://x.example'; BuildArg = @('VITE_API_URL=https://y.example'); Yes = $true } } | Should Throw 'VITE_API_URL'
    }
}

Describe 'set-secret' {
    AfterEach { Restore-Fakes }
    BeforeEach {
        $script:Plain = 'sk-test-' + 'Z9q8w7e6r5t4y3'
        Mock Read-SecretValue { $script:Plain }
        Mock Read-TypedWord {}
    }

    It 'refuses a key outside <SERVICE>__<VAR> before any secrets call' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        { Run 'set-secret' 'pulso-prod' @{ SecretKey = 'openrouter' } } | Should Throw 'SecretKey'
        { Run 'set-secret' 'pulso-prod' @{ SecretKey = 'OTHER__X' } } | Should Throw 'SecretKey'
        { Run 'set-secret' 'pulso-prod' @{} } | Should Throw 'SecretKey'
        Get-Calls | Should Not Match 'secretsmanager'
    }

    It 'sets only that key of pulso-prod/hackathon from the prompt and never prints or logs the value' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-Resp 'secretsmanager-get-secret-value' '{"GATEWAY__OPENROUTER_API_KEY":"CHANGE_ME","CORE__AGENTCORE_REGISTRY_DSN":"postgres://keep"}'
        $out = Run 'set-secret' 'pulso-prod' @{ SecretKey = 'GATEWAY__OPENROUTER_API_KEY' }
        $calls = Get-Calls
        $calls | Should Match 'secretsmanager get-secret-value --secret-id pulso-prod/hackathon'
        $calls | Should Match 'secretsmanager put-secret-value --secret-id pulso-prod/hackathon --secret-string file://'
        $calls | Should Not Match ([regex]::Escape($script:Plain))
        $out | Should Not Match ([regex]::Escape($script:Plain))
        $out | Should Match 'GATEWAY__OPENROUTER_API_KEY'
    }

    It 'writes the merged JSON through a temp file outside the repo and deletes it' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        $script:Captured = $null; $script:CapturedPath = $null
        Mock Invoke-Aws {
            if ($CliArgs[0] -eq 'secretsmanager' -and $CliArgs[1] -eq 'get-secret-value') { return '{"GATEWAY__OPENROUTER_API_KEY":"CHANGE_ME","CORE__AGENTCORE_REGISTRY_DSN":"postgres://keep"}' }
            if ($CliArgs[1] -eq 'put-secret-value') {
                $f = ($CliArgs | Where-Object { $_ -like 'file://*' }) -replace '^file://', ''
                $script:CapturedPath = $f; $script:Captured = Get-Content -Raw $f
                return
            }
            '{"UserId":"x","Account":"000000000000","Arn":"arn:aws:iam::000000000000:user/x"}'
        }
        Run 'set-secret' 'pulso-prod' @{ SecretKey = 'GATEWAY__OPENROUTER_API_KEY' } | Out-Null
        $j = $script:Captured | ConvertFrom-Json
        $j.GATEWAY__OPENROUTER_API_KEY | Should Be $script:Plain
        $j.CORE__AGENTCORE_REGISTRY_DSN | Should Be 'postgres://keep'
        $script:CapturedPath.StartsWith($script:RepoRoot, [StringComparison]::OrdinalIgnoreCase) | Should Be $false
        Test-Path $script:CapturedPath | Should Be $false
    }

    It 'rejects an empty value and the CHANGE_ME placeholder, and writes nothing' {
        Use-Fakes 'arn:aws:iam::000000000000:user/x'
        Set-Resp 'secretsmanager-get-secret-value' '{"GATEWAY__OPENROUTER_API_KEY":"CHANGE_ME"}'
        $script:Plain = ''
        { Run 'set-secret' 'pulso-prod' @{ SecretKey = 'GATEWAY__OPENROUTER_API_KEY' } } | Should Throw 'empty'
        $script:Plain = 'CHANGE_ME'
        { Run 'set-secret' 'pulso-prod' @{ SecretKey = 'GATEWAY__OPENROUTER_API_KEY' } } | Should Throw 'placeholder'
        Get-Calls | Should Not Match 'put-secret-value'
    }

    It 'has no parameter that carries the value' {
        $names = (Get-Command $script:Target).Parameters.Keys
        foreach ($bad in 'Value', 'SecretValue', 'Secret', 'Password', 'ValueFile', 'FromFile') { ($names -contains $bad) | Should Be $false }
    }
}

