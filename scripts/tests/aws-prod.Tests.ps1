# Pester (3.x style) tests for scripts/aws-prod.ps1. Offline: a fake `aws` and a fake `terraform` are put first on PATH,
# so no real cloud call, credential or terraform process is ever involved.
$script:Target = Join-Path (Split-Path $PSScriptRoot -Parent) 'aws-prod.ps1'
. $script:Target -LibraryOnly

function New-FakeBin([string]$Dir) {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Set-Content -Encoding ascii (Join-Path $Dir 'aws.cmd') @'
@echo off
echo aws %*>>"%FAKE_LOG%"
echo {"UserId":"AIDAFAKE","Account":"%FAKE_ACCOUNT%","Arn":"%FAKE_ARN%"}
exit /b 0
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
    New-Item -ItemType Directory -Force -Path $env:AWS_PROD_WORKDIR | Out-Null
    $script:RootWarned = $false
}

function Restore-Fakes { $env:PATH = $script:OldPath }

function Get-Calls { if (Test-Path $env:FAKE_LOG) { Get-Content $env:FAKE_LOG -Raw } else { '' } }

function Run([string]$Command, [string]$Profile = 'pulso-prod', [hashtable]$Options = @{}, [bool]$AllowAny = $false) {
    $script:RootWarned = $false
    & { Invoke-AwsProd -Command $Command -Profile $Profile -AllowAnyProfile $AllowAny -Options $Options } 6>&1 | Out-String
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
