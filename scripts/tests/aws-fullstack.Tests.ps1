# Pester (3.x style): the full profile (terraform/envs/hackathon/prod.tfvars.complete.example) and the image digests written by
# scripts/aws-prod.ps1. Offline, no fake aws needed: only the tfvars file helpers are exercised.
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'aws-prod.ps1') -LibraryOnly

$script:Complete = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'terraform/envs/hackathon/prod.tfvars.complete.example'
$script:D = 'sha256:' + ('b' * 64)

Describe 'Set-ImagesInTfvars with the complete profile' {
    It 'reads every slot of the complete example, optional ones included' {
        $refs = Get-ImageRefsFromTfvars $script:Complete
        foreach ($k in 'gateway', 'agent', 'tools', 'forwarder', 'support_api', 'support_web', 'proxy', 'pulso', 'pipeline') { $refs.ContainsKey($k) | Should Be $true }
    }

    It 'building one service keeps the slots and the digests of the others (agent, tools, pipeline, forwarder)' {
        $f = Join-Path $TestDrive 'p.tfvars'
        Copy-Item $script:Complete $f
        $refs = Get-ImageRefsFromTfvars $f
        $refs['agent'] = "000000000000.dkr.ecr.us-east-1.amazonaws.com/pulso-prod/agent-core-serve@$($script:D)"
        Set-ImagesInTfvars $f $refs
        $refs2 = Get-ImageRefsFromTfvars $f
        $refs2['agent'] | Should Be $refs['agent']
        $refs2.ContainsKey('tools') | Should Be $true
        $refs2.ContainsKey('pipeline') | Should Be $true
        $refs2.ContainsKey('forwarder') | Should Be $true
        # a second build of another service must not drop the first digest
        $refs2['tools'] = "000000000000.dkr.ecr.us-east-1.amazonaws.com/pulso-prod/tool-service@$($script:D)"
        Set-ImagesInTfvars $f $refs2
        $refs3 = Get-ImageRefsFromTfvars $f
        $refs3['agent'] | Should Be $refs['agent']
        $refs3['tools'] | Should Be $refs2['tools']
        (Get-Content -Raw $f) | Should Not Match '(?m)^\s*core\s*=\s*"'
    }

    It 'places forwarder in both the core and the engine block, and pipeline only in the engine block' {
        $f = Join-Path $TestDrive 'q.tfvars'
        Copy-Item $script:Complete $f
        Set-ImagesInTfvars $f (Get-ImageRefsFromTfvars $f)
        $t = Get-Content -Raw $f
        $core = [regex]::Match($t, '(?ms)^  core = \{.*?^  \}').Value
        $engine = [regex]::Match($t, '(?ms)^  engine = \{.*?^  \}').Value
        $core | Should Match 'forwarder'
        $core | Should Match 'agent'
        $core | Should Match 'tools'
        $core | Should Not Match 'pipeline'
        $engine | Should Match 'forwarder'
        $engine | Should Match 'pipeline'
    }

    It 'still writes the legacy core digest for a profile without agent services (unchanged behaviour)' {
        $f = Join-Path $TestDrive 'r.tfvars'
        Set-Content $f "images = {`n  core = {}`n}`n"
        $d = 'sha256:' + ('a' * 64)
        $refs = @{}; foreach ($k in 'core', 'gateway', 'support_api', 'support_web', 'proxy', 'pulso') { $refs[$k] = "r/$k@$d" }
        Set-ImagesInTfvars $f $refs
        $t = Get-Content -Raw $f
        $t | Should Match 'core    = "r/core@sha256:a{64}"'
        $t | Should Not Match 'agent'
    }

    It 'the placeholder check of plan still refuses the complete example until every image is built' {
        { Resolve-VarFile $script:Complete } | Should Throw 'placeholders'
    }
}
