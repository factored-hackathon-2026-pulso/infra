# Pester (3.x style) tests for scripts/aws-acceptance.ps1. Offline: the two functions that start a process (Invoke-Curl and
# Invoke-AwsCli) are mocked, so no HTTP call, aws call or credential is ever involved. The mocks answer from tables set per test.
$script:Target = Join-Path (Split-Path $PSScriptRoot -Parent) 'aws-acceptance.ps1'
. $script:Target -LibraryOnly

$script:Jwt = 'eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJzdXBlcnZpc29yIn0.c2lnbmF0dXJlLXNpZ25hdHVyZQ'
$script:CustJwt = 'eyJhbGciOiJFZERTQSJ9.eyJzdWIiOiJjdXN0b21lciJ9.Y3VzdG9tZXItc2lnbmF0dXJl'

function New-Resp([int]$Status, $Object) {
    $body = if ($Object -is [string]) { $Object } elseif ($null -ne $Object) { $Object | ConvertTo-Json -Depth 6 -Compress } else { '' }
    [pscustomobject]@{ Status = $Status; Body = $body; Error = '' }
}

$script:Html = '<!doctype html><html><head><script type="module" src="/assets/index-abc.js"></script></head><body><div id="root"></div></body></html>'

function Initialize-Http {
    # The happy path of every platform call; a test overrides single entries in $global:AccHttp.
    $global:AccHttp = @{
        'GET /'                                        = (New-Resp 200 $script:Html)
        'GET /api/v1/health'                           = (New-Resp 200 @{ status = 'ok'; checks = @{ database = 'ok'; core = 'ok' } })
        'GET /api/v1/meta'                             = (New-Resp 200 @{ name = 'cc-platform'; version = '1.2.3'; environment = 'staging'; devMailbox = $true })
        'POST /api/v1/auth/login'                      = (New-Resp 200 @{ mfaRequired = $true; challengeId = 'ch-1'; methods = @('totp') })
        'POST /api/v1/auth/mfa'                        = (New-Resp 200 @{ token = $script:Jwt; tokenType = 'Bearer' })
        'GET /api/v1/auth/me'                          = (New-Resp 200 @{ staff = @{ id = 's5' } })
        'GET /api/v1/customer/demo-customers'          = (New-Resp 200 @{ items = @(@{ id = 'CLI-0001'; displayName = 'Ana' }) })
        'POST /api/v1/customer/sessions'               = (New-Resp 201 @{ token = $script:CustJwt })
        'POST /api/v1/customer/conversation/turns'     = (New-Resp 201 @{ caseCreated = $true })
        'GET /api/v1/customer/conversation'            = (New-Resp 200 @{ turns = @(@{ authorRole = 'customer'; text = 'hola' }, @{ authorRole = 'assistant'; text = 'respuesta' }) })
        'GET /pulso/readyz'                            = (New-Resp 200 @{ status = 'ready' })
        'GET /api/v1/builder/proposals'                = (New-Resp 200 @{ items = @(@{ proposalId = 'p-1'; agentId = 'consultas'; state = 'draft'; source = 'engine' }) })
    }
    $global:AccHttpLog = New-Object System.Collections.Generic.List[string]
}

function Initialize-Aws {
    $global:AccAws = @{}
    $global:AccAwsLog = New-Object System.Collections.Generic.List[string]
    $global:AccHostOut = ''
}

function Set-Acc([hashtable]$Overrides = @{}) {
    $script:Cfg = @{
        Profile = ''; AllowAnyProfile = $false; BaseUrl = 'https://d111.cloudfront.net'; NamePrefix = 'pulso-prod'; Bucket = ''
        SupervisorEmail = 'lucia.herrera@latambank.example'; DemoPassword = 'demo1234'; MfaCode = '000000'; CustomerMessage = 'hola'
        ChatWaitSeconds = 5; HostChecks = 'Print'; Only = @(); ReportFile = ''
    }
    foreach ($k in $Overrides.Keys) { $script:Cfg[$k] = $Overrides[$k] }
    $env:AWS_PROD_WORKDIR = Join-Path $TestDrive 'work'
}

function Invoke-Acc {
    $all = @(Invoke-Acceptance 6>&1)
    $code = [int]($all | Where-Object { $_ -is [int] } | Select-Object -Last 1)
    $text = (($all | Where-Object { $_ -isnot [int] } | ForEach-Object { "$_" }) -join "`n")
    [pscustomobject]@{ Code = $code; Text = $text }
}

Describe 'aws-acceptance.ps1 (mocked curl and aws)' {
    BeforeEach {
        Initialize-Http
        Initialize-Aws
        Set-Acc
        Mock Start-Sleep {}
        Mock Invoke-Curl {
            $verb = if ($Method) { $Method } else { 'GET' }   # Pester mocks do not keep the default parameter values
            $key = "$verb " + ($Url -replace '^https://[^/]+', '' -replace '\?.*$', '')
            $global:AccHttpLog.Add("$key token=$([bool]$BearerToken)")
            if ($global:AccHttp.ContainsKey($key)) { return $global:AccHttp[$key] }
            [pscustomobject]@{ Status = 404; Body = ''; Error = '' }
        }
        Mock Invoke-AwsCli {
            $line = $CliArgs -join ' '
            $global:AccAwsLog.Add($line)
            foreach ($k in $global:AccAws.Keys) { if ($line -like "*$k*") { return $global:AccAws[$k] } }
            [pscustomobject]@{ Exit = 255; Out = 'not mocked' }
        }
    }
    AfterEach {
        Remove-Variable -Name AccHttp, AccHttpLog, AccAws, AccAwsLog, AccHostOut -Scope Global -ErrorAction SilentlyContinue
        $env:AWS_PROD_WORKDIR = $null
    }

    It 'passes the four platform checks, prints the SSM commands for the host-side ones, and exits 0' {
        $r = Invoke-Acc
        $r.Text | Should Match 'PASS\s+edge-spa'
        $r.Text | Should Match 'PASS\s+platform-health.*environment staging'
        $r.Text | Should Match 'PASS\s+demo-login'
        $r.Text | Should Match 'PASS\s+customer-chat.*assistant answered'
        $r.Text | Should Match 'PASS\s+engine-edge'
        $r.Text | Should Match 'PASS\s+engine-announce.*source engine'
        $r.Text | Should Match 'SKIP\s+agent-core-ready\s+host-side'
        $r.Text | Should Match 'aws ssm send-command --profile <profile> --region us-east-1 --document-name AWS-RunShellScript --targets "Key=tag:Workload,Values=core"'
        $r.Text | Should Match 'Key=tag:Workload,Values=engine'
        $r.Code | Should Be 0
    }

    It 'never prints a token, the demo password or an Authorization header' {
        $r = Invoke-Acc
        $r.Text | Should Not Match ([regex]::Escape($script:Jwt))
        $r.Text | Should Not Match ([regex]::Escape($script:CustJwt))
        $r.Text | Should Not Match 'demo1234'
        $r.Text | Should Not Match '(?i)bearer\s'
    }

    It 'writes the host-side command documents with read-only commands and no secret' {
        Invoke-Acc | Out-Null
        $docs = @(Get-ChildItem (Join-Path $TestDrive 'work') -Filter 'host-check-*.json')
        ($docs | ForEach-Object { $_.Name }) -contains 'host-check-agent-core-ready.json' | Should Be $true
        $core = Get-Content -Raw (Join-Path $TestDrive 'work\host-check-agent-core-ready.json')
        $core | Should Match '127\.0\.0\.1:8001/readyz'
        $loop = Get-Content -Raw (Join-Path $TestDrive 'work\host-check-engine-loop-check.json')
        $loop | Should Match 'pulso-loop loop --check'
        $loop | Should Match 'systemctl|docker compose'
        foreach ($d in $docs) { (Get-Content -Raw $d.FullName) | Should Not Match '(?i)password|secret|token' }
    }

    It 'FAILs the health check when a probe is failing, and exits 1 while the later checks still run' {
        $global:AccHttp['GET /api/v1/health'] = New-Resp 503 @{ status = 'failing'; checks = @{ database = 'ok'; core = 'failing' } }
        $r = Invoke-Acc
        $r.Text | Should Match 'FAIL\s+platform-health.*failing: core'
        $r.Text | Should Match 'PASS\s+demo-login'
        $r.Code | Should Be 1
    }

    It 'FAILs when the environment is not staging (the demo accounts would not exist)' {
        $global:AccHttp['GET /api/v1/meta'] = New-Resp 200 @{ version = '1'; environment = 'prod' }
        $r = Invoke-Acc
        $r.Text | Should Match "FAIL\s+platform-health.*'prod', not staging"
        $r.Code | Should Be 1
    }

    It 'FAILs the SPA check on a 403, on a 502 and on a body that is not the SPA' {
        $global:AccHttp['GET /'] = New-Resp 403 ''
        (Invoke-Acc).Text | Should Match 'FAIL\s+edge-spa\s+HTTP 403.*X-Origin-Verify'
        $global:AccHttp['GET /'] = New-Resp 502 ''
        (Invoke-Acc).Text | Should Match 'FAIL\s+edge-spa\s+HTTP 502'
        $global:AccHttp['GET /'] = New-Resp 200 '{"not":"html"}'
        (Invoke-Acc).Text | Should Match 'FAIL\s+edge-spa.*not the SPA'
    }

    It 'FAILs everything that needs the URL when there is none, with the way out' {
        Set-Acc @{ BaseUrl = '' }
        $r = Invoke-Acc
        $r.Text | Should Match 'FAIL\s+edge-spa\s+no CloudFront URL: pass -BaseUrl'
        $r.Text | Should Match 'SKIP\s+platform-health'
        $r.Code | Should Be 1
    }

    It 'a refused login says the seed did not run, and engine-announce is then skipped' {
        $global:AccHttp['POST /api/v1/auth/login'] = New-Resp 401 @{ code = 'invalid_credentials' }
        $r = Invoke-Acc
        $r.Text | Should Match 'FAIL\s+demo-login.*401.*invalid_credentials.*seed'
        $r.Text | Should Match 'SKIP\s+engine-announce\s+no supervisor session'
        $r.Code | Should Be 1
    }

    It 'a wrong MFA answer FAILs and names the staging dev code requirement' {
        $global:AccHttp['POST /api/v1/auth/mfa'] = New-Resp 401 @{ code = 'mfa_invalid' }
        (Invoke-Acc).Text | Should Match 'FAIL\s+demo-login.*mfa.*mfa_invalid.*staging'
    }

    It 'FAILs the chat when no demo customers exist (seed missing) and when no assistant turn arrives' {
        $global:AccHttp['GET /api/v1/customer/demo-customers'] = New-Resp 200 @{ items = @() }
        (Invoke-Acc).Text | Should Match 'FAIL\s+customer-chat.*no demo customers'
        Initialize-Http
        Set-Acc @{ ChatWaitSeconds = 0 }
        $global:AccHttp['GET /api/v1/customer/conversation'] = New-Resp 200 @{ turns = @(@{ authorRole = 'customer' }) }
        (Invoke-Acc).Text | Should Match 'FAIL\s+customer-chat.*no assistant turn within 0s'
    }

    It 'FAILs the chat when the platform refuses the customer turn' {
        $global:AccHttp['POST /api/v1/customer/conversation/turns'] = New-Resp 503 @{ code = 'agent_core_unavailable' }
        (Invoke-Acc).Text | Should Match 'FAIL\s+customer-chat.*503.*agent_core_unavailable'
    }

    It 'FAILs engine-announce when no proposal comes from the engine' {
        $global:AccHttp['GET /api/v1/builder/proposals'] = New-Resp 200 @{ items = @(@{ proposalId = 'p-2'; agentId = 'x'; state = 'draft'; source = 'platform' }) }
        $r = Invoke-Acc
        $r.Text | Should Match 'FAIL\s+engine-announce.*none with source engine'
        $r.Code | Should Be 1
    }

    It 'FAILs the engine edge route while the engine is not ready' {
        $global:AccHttp['GET /pulso/readyz'] = New-Resp 503 @{ reason = 'migrations_pending' }
        (Invoke-Acc).Text | Should Match 'FAIL\s+engine-edge.*503'
    }

    It 'refuses the protected profile names, with and without -AllowAnyProfile' {
        Set-Acc @{ Profile = 'default' }
        { Invoke-Acceptance 6>&1 | Out-Null } | Should Throw 'Refusing profile'
        Set-Acc @{ Profile = 'standar-prod' }
        { Invoke-Acceptance 6>&1 | Out-Null } | Should Throw 'Refusing profile'
    }

    It 'rejects a base URL that is not https://<domain>' {
        Set-Acc @{ BaseUrl = 'http://d111.cloudfront.net/x' }
        { Invoke-Acceptance 6>&1 | Out-Null } | Should Throw '-BaseUrl'
    }

    It 'looks the CloudFront domain and the bucket up with read-only aws calls when a profile is given' {
        Set-Acc @{ Profile = 'pulso-prod'; BaseUrl = '' ; Only = @('edge-spa', 'loader-marker') }
        $global:AccAws['cloudfront list-distributions'] = [pscustomobject]@{ Exit = 0; Out = 'dabc123xyz.cloudfront.net' }
        $global:AccAws['sts get-caller-identity'] = [pscustomobject]@{ Exit = 0; Out = '000000000000' }
        $global:AccAws['head-object'] = [pscustomobject]@{ Exit = 0; Out = '120' }
        $global:AccAws['s3 cp'] = [pscustomobject]@{ Exit = 0; Out = '{"state":"ok","run":"abcd1234abcd1234","at":"2026-10-06T10:00:00Z","detail":"loaded"}' }
        $r = Invoke-Acc
        $r.Text | Should Match 'URL https://dabc123xyz\.cloudfront\.net'
        $r.Text | Should Match 'PASS\s+loader-marker.*state ok for run abcd1234abcd1234'
        ($global:AccAwsLog -join "`n") | Should Match 'head-object --bucket pulso-prod-data-000000000000 --key engine/inbox/READY\.json'
        # Only reads: no put, delete, update, create or send in any aws call of this run.
        ($global:AccAwsLog -join "`n") | Should Not Match '(?i)\b(put-|delete|update-|create-|send-command|start-|terminate|run-instances)'
    }

    It 'FAILs the loader check when the marker is missing, or the loader reports failed' {
        Set-Acc @{ Profile = 'pulso-prod'; Bucket = 'pulso-prod-data-000000000000'; Only = @('loader-marker') }
        (Invoke-Acc).Text | Should Match 'FAIL\s+loader-marker.*READY\.json is missing'
        $global:AccAws['head-object'] = [pscustomobject]@{ Exit = 0; Out = '1' }
        $global:AccAws['s3 cp'] = [pscustomobject]@{ Exit = 0; Out = '{"state":"failed","run":"r","at":"t","detail":"exit 3"}' }
        (Invoke-Acc).Text | Should Match "FAIL\s+loader-marker.*'failed'"
    }

    It 'checks the lake zones, the publication pointer and the loop cells' {
        Set-Acc @{ Profile = 'pulso-prod'; Bucket = 'pulso-prod-data-000000000000'; Only = @('lake-zones') }
        $global:AccAws['list-objects-v2'] = [pscustomobject]@{ Exit = 0; Out = "lake/bronze/`tlake/silver/`tlake/gold_masked/`tlake/gold_analytics/`tlake/gold_restricted/`tlake/publish/" }
        $global:AccAws['head-object'] = [pscustomobject]@{ Exit = 0; Out = '1' }
        (Invoke-Acc).Text | Should Match 'PASS\s+lake-zones.*loader cells'
        $global:AccAws['list-objects-v2'] = [pscustomobject]@{ Exit = 0; Out = "lake/bronze/`tlake/silver/" }
        (Invoke-Acc).Text | Should Match 'FAIL\s+lake-zones.*missing: lake/gold_masked/'
        $global:AccAws['list-objects-v2'] = [pscustomobject]@{ Exit = 0; Out = "lake/bronze/`tlake/silver/`tlake/gold_masked/`tlake/gold_analytics/`tlake/gold_restricted/`tlake/publish/" }
        $global:AccAws.Remove('head-object')
        $global:AccAws['head-object'] = [pscustomobject]@{ Exit = 255; Out = 'Not Found' }
        (Invoke-Acc).Text | Should Match 'FAIL\s+lake-zones.*lake/publish/latest\.json is missing'
    }

    It 'skips S3 checks without a profile instead of failing them' {
        Set-Acc @{ Only = @('loader-marker', 'lake-zones') }
        $r = Invoke-Acc
        $r.Text | Should Match 'SKIP\s+loader-marker\s+no -Profile'
        $r.Text | Should Match 'SKIP\s+lake-zones\s+no -Profile'
        $r.Code | Should Be 0
    }

    It '-Only limits the run to the named checks' {
        Set-Acc @{ Only = @('edge-spa') }
        $r = Invoke-Acc
        $r.Text | Should Match 'PASS\s+edge-spa'
        $r.Text | Should Not Match 'platform-health'
        $r.Text | Should Not Match 'demo-login'
    }

    It '-HostChecks Run sends the read-only command through SSM and judges the output (agent-core ready)' {
        Set-Acc @{ Profile = 'pulso-prod'; HostChecks = 'Run'; Only = @('agent-core-ready') }
        $global:AccAws['describe-instances'] = [pscustomobject]@{ Exit = 0; Out = 'i-0123456789abcdef0' }
        $global:AccAws['send-command'] = [pscustomobject]@{ Exit = 0; Out = '11111111-2222-3333-4444-555555555555' }
        $global:AccAws['--query Status'] = [pscustomobject]@{ Exit = 0; Out = 'Success' }
        $global:AccAws['StandardOutputContent'] = [pscustomobject]@{ Exit = 0; Out = "{`"status`":`"ready`",`"checks`":{`"postgres`":`"ok`",`"keys`":`"ok`",`"schema`":`"ok`",`"llm_gateway`":`"ok`",`"tool_service`":`"ok`"}}`nHTTP 200" }
        $r = Invoke-Acc
        $r.Text | Should Match 'PASS\s+agent-core-ready\s+HTTP 200, status ready \(postgres=ok'
        ($global:AccAwsLog -join "`n") | Should Match 'ssm send-command --instance-ids i-0123456789abcdef0'
        $r.Code | Should Be 0
    }

    It '-HostChecks Run FAILs when agent-core is degraded, when tool-service is not ready and when no instance runs' {
        Set-Acc @{ Profile = 'pulso-prod'; HostChecks = 'Run'; Only = @('agent-core-ready') }
        $global:AccAws['describe-instances'] = [pscustomobject]@{ Exit = 0; Out = 'i-0123456789abcdef0' }
        $global:AccAws['send-command'] = [pscustomobject]@{ Exit = 0; Out = '11111111-2222-3333-4444-555555555555' }
        $global:AccAws['--query Status'] = [pscustomobject]@{ Exit = 0; Out = 'Success' }
        $global:AccAws['StandardOutputContent'] = [pscustomobject]@{ Exit = 0; Out = "{`"status`":`"not_ready`",`"checks`":{`"postgres`":`"ok`",`"llm_gateway`":`"failed`"}}`nHTTP 503" }
        (Invoke-Acc).Text | Should Match 'FAIL\s+agent-core-ready.*llm_gateway=failed'
        Set-Acc @{ Profile = 'pulso-prod'; HostChecks = 'Run'; Only = @('tool-service-ready') }
        $global:AccAws['StandardOutputContent'] = [pscustomobject]@{ Exit = 0; Out = 'Traceback (most recent call last): HTTPError 503' }
        (Invoke-Acc).Text | Should Match 'FAIL\s+tool-service-ready.*not 200'
        $global:AccAws.Remove('describe-instances')
        $global:AccAws['describe-instances'] = [pscustomobject]@{ Exit = 0; Out = 'None' }
        (Invoke-Acc).Text | Should Match 'FAIL\s+tool-service-ready.*no running instance with Workload=core'
    }

    It '-HostChecks Run without a profile skips instead of calling aws' {
        Set-Acc @{ HostChecks = 'Run'; Only = @('gateway-ready') }
        $r = Invoke-Acc
        $r.Text | Should Match 'SKIP\s+gateway-ready\s+host-side check: -HostChecks Run needs -Profile'
        $global:AccAwsLog.Count | Should Be 0
    }

    It 'writes a JSON report with PASS, FAIL and SKIP and no secret' {
        $report = Join-Path $TestDrive 'report.json'
        Set-Acc @{ ReportFile = $report }
        Invoke-Acc | Out-Null
        $j = Get-Content -Raw $report
        $j | Should Match '"Status":\s*"PASS"'
        $j | Should Match '"Status":\s*"SKIP"'
        $j | Should Not Match ([regex]::Escape($script:Jwt))
    }
}

Describe 'host output verdicts' {
    It 'loop --check needs cells_present, proof and exit 0' {
        (Test-LoopCheck "{`"auth_mode`":`"engine builder principal (minted)`",`"cells_present`":true,`"proof`":true}`nEXIT=0").Ok | Should Be $true
        (Test-LoopCheck "{`"cells_present`":false,`"proof`":true}`nEXIT=0").Reason | Should Match 'cells_present'
        (Test-LoopCheck "{`"cells_present`":true,`"proof`":false}`nEXIT=2").Reason | Should Match 'proof .*regression'
        (Test-LoopCheck 'EXIT=2').Ok | Should Be $false
    }

    It 'the loop unit needs an active timer, Result=success, a finished run and no FAILED marker' {
        $good = "active`nActiveState=inactive`nSubState=dead`nResult=success`nExecMainStatus=0`nExecMainExitTimestamp=Tue 2026-10-06 10:00:00 UTC`nFAILED_MARKER=absent"
        (Test-LoopUnit $good).Ok | Should Be $true
        (Test-LoopUnit ($good -replace 'FAILED_MARKER=absent', 'FAILED_MARKER=present')).Reason | Should Match 'FAILED'
        (Test-LoopUnit ($good -replace 'Result=success', 'Result=exit-code')).Ok | Should Be $false
        (Test-LoopUnit ($good -replace 'ExecMainStatus=0', 'ExecMainStatus=3')).Reason | Should Match 'last exit status 3'
        (Test-LoopUnit ($good -replace 'ExecMainExitTimestamp=[^\n]*', 'ExecMainExitTimestamp=')).Reason | Should Match 'has not run yet'
        (Test-LoopUnit ($good -replace '^active', 'inactive')).Reason | Should Match 'timer is not active'
        (Test-LoopUnit ($good -replace 'ExecMainStatus=0', 'ExecMainStatus=75')).Ok | Should Be $true
    }

    It 'the forwarder checks count the sidecars that answered 200' {
        (Test-ForwarderCore "HTTP 200 {}`nHTTP 200 {}").Ok | Should Be $true
        (Test-ForwarderCore 'HTTP 200 {}').Reason | Should Match '1 of 2'
        (Test-ForwarderEngine 'HTTP 200 {}').Ok | Should Be $true
        (Test-ForwarderEngine '').Ok | Should Be $false
    }

    It 'the gateway check is the liveness probe only' {
        (Test-GatewayReady "ok`nHTTP 200").Ok | Should Be $true
        (Test-GatewayReady 'HTTP 502').Ok | Should Be $false
    }
}

Describe 'helpers' {
    It 'Protect-Text masks JWTs, bearer headers and the demo password' {
        Set-Acc
        (Protect-Text "token $($script:Jwt) end") | Should Be 'token <token> end'
        (Protect-Text 'Authorization: Bearer abcdefghijkl123456') | Should Not Match 'abcdefghijkl'
        (Protect-Text 'password demo1234 here') | Should Be 'password <redacted> here'
    }

    It 'ConvertTo-CurlValue escapes quotes, backslashes and newlines for a curl config' {
        ConvertTo-CurlValue 'a"b\c' | Should Be 'a\"b\\c'
        ConvertTo-CurlValue "x`ny" | Should Be 'x\ny'
    }

    It 'the script has no parameter that takes a secret and exits non-zero on FAIL' {
        $text = Get-Content -Raw $script:Target
        $text | Should Not Match '(?i)\[string\]\$(token|secret|apikey)'
        $text | Should Match 'if \(\$fail -gt 0\) \{ return 1 \}'
    }
}
