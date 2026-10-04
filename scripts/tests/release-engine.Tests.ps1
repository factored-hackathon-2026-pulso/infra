# Pester (3.x/5.x compatible) tests for scripts/release-engine.ps1. Offline: no container engine, no AWS.
$script:Target = Join-Path (Split-Path $PSScriptRoot -Parent) 'release-engine.ps1'
. $script:Target -LibraryOnly

$good = 'sha256:' + ('a' * 64)
$sha = 'b' * 40

Describe 'Assert-Digest' {
    It 'accepts a sha256 digest' { Assert-Digest $good | Should Be $good }
    It 'refuses an empty digest' { { Assert-Digest '' } | Should Throw 'digest' }
    It 'refuses a tag-like value' { { Assert-Digest 'latest' } | Should Throw 'digest' }
}

Describe 'Assert-PushAllowed' {
    It 'is a no-op without -Push' { Assert-PushAllowed -Push:$false -AwsProfile '' -Digest '' }
    It 'refuses -Push without a profile' { { Assert-PushAllowed -Push:$true -AwsProfile '' -Digest $good } | Should Throw 'profile' }
    It 'refuses -Push for the unrelated default profile' { { Assert-PushAllowed -Push:$true -AwsProfile 'default' -Digest $good } | Should Throw 'profile' }
    It 'refuses -Push without a digest' { { Assert-PushAllowed -Push:$true -AwsProfile 'pulso-new' -Digest '' } | Should Throw 'digest' }
    It 'allows -Push with an explicit profile and digest' { Assert-PushAllowed -Push:$true -AwsProfile 'pulso-new' -Digest $good }
}

Describe 'New-DeployManifest' {
    It 'records digest, git sha, sbom hash and timestamp' {
        $m = New-DeployManifest -ImageDigest $good -GitSha $sha -SbomSha256 ('c' * 64) -Pushed $false
        $m.image_digest | Should Be $good
        $m.git_sha | Should Be $sha
        $m.sbom_sha256 | Should Be ('c' * 64)
        $m.pushed | Should Be $false
        ([datetime]::Parse($m.created_utc)).Year | Should BeGreaterThan 2025
    }
    It 'refuses a manifest without a digest' { { New-DeployManifest -ImageDigest '' -GitSha $sha -SbomSha256 '' -Pushed $false } | Should Throw 'digest' }
    It 'never fakes the sbom: an absent SBOM is recorded as skipped with a reason' {
        $m = New-DeployManifest -ImageDigest $good -GitSha $sha -SbomSha256 '' -Pushed $false -SbomSkipReason 'syft not installed'
        $m.sbom_sha256 | Should BeNullOrEmpty
        $m.sbom_skipped | Should Be 'syft not installed'
    }
    It 'refuses a missing sbom without a reason' { { New-DeployManifest -ImageDigest $good -GitSha $sha -SbomSha256 '' -Pushed $false } | Should Throw 'sbom' }
}

Describe 'script entry point' {
    It 'refuses -Push with no profile before touching any tool' {
        $out = & pwsh -NoProfile -File $script:Target -Push 2>&1 | Out-String
        $LASTEXITCODE | Should Not Be 0
        $out | Should Match 'profile'
    }
}
