<#
.SYNOPSIS
  Full-system acceptance of the AWS deployment, in order, one PASS / FAIL / SKIP line per check (docs/infra-day-one.md, layer 10).
.DESCRIPTION
  Read-only. Nothing is created, changed or deleted in AWS, and no secret is read or printed. The checks, in order:

    edge-spa            CloudFront URL up, the SPA is served
    platform-health     the platform API through the edge: /api/v1/health (database and Core probes) and /api/v1/meta (staging)
    demo-login          a seeded demo supervisor logs in with the dev MFA code (API calls, no browser)
    customer-chat       a customer simulator session writes to the assistant and an assistant turn comes back
                        (an agent-core run created through the platform)
    agent-core-ready    host-side: agent-core serve /readyz on the core host
    gateway-ready       host-side: llm-gateway /healthz on the core host
    tool-service-ready  host-side: tool-service /readyz (a publication is mounted)
    loader-marker       S3 (read only): engine/inbox/READY.json and the loader status engine/loader/status/last.json
    lake-zones          S3 (read only): the lake zones, lake/publish/latest.json and the loop cells
    engine-edge         the engine through the edge: /pulso/readyz
    engine-loop-check   host-side: `pulso loop --check`
    engine-loop-unit    host-side: systemctl pulso-loop and its timer, no FAILED marker
    engine-announce     the proposal announced by the engine is in the platform Automatizacion list (source engine)
    forwarder           host-side: the OTLP forwarder sidecars answer /healthz

  Host-side checks need a shell ON the hosts. By default (-HostChecks Print) they are SKIP lines and the exact `aws ssm send-command`
  commands are printed (the command documents are written to the work directory). With -HostChecks Run the script sends those same
  read-only commands itself and judges the output.

  Secrets: tokens exist only in memory and are handed to curl on its standard input (a curl config), never in a command line, a file,
  a log or the output. The only credentials involved are the synthetic demo account of the staging platform (CC_ENV=staging).
  Exit code: 0 when nothing FAILED, 1 when at least one check FAILED, 2 when the script was misused.
.EXAMPLE
  ./scripts/aws-acceptance.ps1 -Profile pulso-prod
  ./scripts/aws-acceptance.ps1 -Profile pulso-prod -HostChecks Run
  ./scripts/aws-acceptance.ps1 -BaseUrl https://dxxxxxxxxxxxx.cloudfront.net -Only edge-spa,platform-health,demo-login
#>
[CmdletBinding()]
param(
    [string]$Profile = '',
    [switch]$AllowAnyProfile,
    [string]$BaseUrl = '',
    [string]$NamePrefix = 'pulso-prod',
    [string]$Bucket = '',
    [string]$SupervisorEmail = 'lucia.herrera@latambank.example',
    [string]$DemoPassword = 'demo1234',
    [string]$MfaCode = '000000',
    [string]$CustomerMessage = 'Hola, quiero consultar el estado de mi tarjeta',
    [int]$ChatWaitSeconds = 90,
    [ValidateSet('Print', 'Run')][string]$HostChecks = 'Print',
    [string[]]$Only = @(),
    [string]$ReportFile = '',
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

# Everything below reads its options from $script:Cfg (the Pester tests replace it); the script parameters fill it.
$script:Cfg = @{
    Profile = $Profile; AllowAnyProfile = [bool]$AllowAnyProfile; BaseUrl = $BaseUrl; NamePrefix = $NamePrefix; Bucket = $Bucket
    SupervisorEmail = $SupervisorEmail; DemoPassword = $DemoPassword; MfaCode = $MfaCode; CustomerMessage = $CustomerMessage
    ChatWaitSeconds = $ChatWaitSeconds; HostChecks = $HostChecks; Only = @($Only); ReportFile = $ReportFile
}
$script:Region = 'us-east-1'
$script:RefusedProfile = '^(default|payana.*|higo.*|standar.*|management.*)$'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Tokens = @{ Supervisor = ''; Customer = '' }
$script:Ctx = @{ Base = ''; Profile = ''; Bucket = ''; ProfileOk = $false }
$script:HostPrinted = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------------------------------------------------
function Protect-Text([string]$Text) {
    # Never let a token or a bearer header reach the console, the report or the log.
    if (-not $Text) { return '' }
    $t = [regex]::Replace($Text, 'eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(\.[A-Za-z0-9_-]*)?', '<token>')
    $t = [regex]::Replace($t, '(?i)(bearer|authorization:?)\s+[A-Za-z0-9._~+/=-]{8,}', '$1 <redacted>')
    foreach ($v in @($script:Tokens.Supervisor, $script:Tokens.Customer, $script:Cfg.DemoPassword)) { if ($v -and $v.Length -ge 6) { $t = $t.Replace($v, '<redacted>') } }
    $t
}

function Add-Result([string]$Id, [ValidateSet('PASS', 'FAIL', 'SKIP')][string]$Status, [string]$Reason) {
    $r = [pscustomobject]@{ Id = $Id; Status = $Status; Reason = (Protect-Text $Reason) }
    $script:Results.Add($r)
    Write-Host ('{0,-4}  {1,-18}  {2}' -f $r.Status, $r.Id, $r.Reason)
}

function Test-Wanted([string]$Id) { (@($script:Cfg.Only).Count -eq 0) -or (@($script:Cfg.Only) -contains $Id) }

# ---------------------------------------------------------------------------------------------------------------------
# External commands: the only two places that start a process (mocked by the Pester tests)
# ---------------------------------------------------------------------------------------------------------------------
function ConvertTo-CurlValue([string]$Value) {
    ($Value -replace '\\', '\\' -replace '"', '\"' -replace "`r", '\r' -replace "`n", '\n')
}

function Invoke-Curl {
    # One HTTP call. The URL, headers and body (which may hold a token or the demo password) go to curl as a config on its
    # standard input: nothing sensitive is ever in a command line or on disk. Returns Status (0 = no answer), Body, Error.
    param([string]$Method = 'GET', [string]$Url, [string]$Token = '', [string]$Body = '', [hashtable]$Headers = @{}, [int]$TimeoutSec = 30)
    $cfg = New-Object System.Collections.Generic.List[string]
    $cfg.Add('url = "' + (ConvertTo-CurlValue $Url) + '"')
    $cfg.Add('request = "' + $Method + '"')
    $cfg.Add('silent')
    $cfg.Add('show-error')
    $cfg.Add('max-time = ' + $TimeoutSec)
    $cfg.Add('write-out = "\n%{http_code}"')
    if ($Token) { $cfg.Add('header = "Authorization: Bearer ' + (ConvertTo-CurlValue $Token) + '"') }
    foreach ($k in $Headers.Keys) { $cfg.Add('header = "' + (ConvertTo-CurlValue ("${k}: " + $Headers[$k])) + '"') }
    if ($Body) {
        $cfg.Add('header = "Content-Type: application/json"')
        $cfg.Add('data = "' + (ConvertTo-CurlValue $Body) + '"')
    }
    $exe = (Get-Command 'curl.exe', 'curl' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    if (-not $exe) { return [pscustomobject]@{ Status = 0; Body = ''; Error = 'curl was not found on PATH' } }
    $out = ($cfg -join "`n") | & $exe.Source -K - 2>&1
    $exit = $LASTEXITCODE
    $text = (@($out) | ForEach-Object { "$_" }) -join "`n"
    if ($exit -ne 0) { return [pscustomobject]@{ Status = 0; Body = ''; Error = (Protect-Text $text) } }
    $i = $text.LastIndexOf("`n")
    $code = if ($i -ge 0) { $text.Substring($i + 1).Trim() } else { $text.Trim() }
    $body = if ($i -ge 0) { $text.Substring(0, $i) } else { '' }
    [pscustomobject]@{ Status = $(if ($code -match '^\d{3}$') { [int]$code } else { 0 }); Body = $body; Error = '' }
}

function Invoke-AwsCli {
    # One read-only aws call, always pinned to the profile and region. Returns Exit and Out (text); never throws.
    param([string[]]$CliArgs)
    $out = & aws @CliArgs --profile $script:Ctx.Profile --region $script:Region 2>&1
    [pscustomobject]@{ Exit = $LASTEXITCODE; Out = ((@($out) | ForEach-Object { "$_" }) -join "`n").Trim() }
}

function ConvertFrom-JsonSafe([string]$Text) { try { $Text | ConvertFrom-Json } catch { $null } }

function Get-Json($Response) { if ($Response.Status -ge 200 -and $Response.Status -lt 300) { ConvertFrom-JsonSafe $Response.Body } else { $null } }

function Get-Prop($Object, [string[]]$Names) {
    # First present property (the API is camelCase; the fallbacks keep the checks tolerant to a snake_case answer).
    foreach ($n in $Names) { if ($Object -and $Object.PSObject.Properties[$n]) { return $Object.PSObject.Properties[$n].Value } }
    $null
}

function Get-FailureText($Response) {
    if ($Response.Status -eq 0) { return "no answer ($($Response.Error))" }
    $detail = ''
    $j = ConvertFrom-JsonSafe $Response.Body
    if ($j) { $d = Get-Prop $j @('code', 'type', 'title', 'detail'); if ($d) { $detail = " [$d]" } }
    "HTTP $($Response.Status)$detail"
}

# ---------------------------------------------------------------------------------------------------------------------
# Context: profile, base URL, bucket
# ---------------------------------------------------------------------------------------------------------------------
function Test-ProfileName([string]$Name, [bool]$AllowAny) {
    if (-not $Name) { return $false }
    if (-not $AllowAny -and $Name -imatch $script:RefusedProfile) { throw "Refusing profile '$Name': default, payana*, higo*, standar* and management* are not allowed targets. Use a dedicated profile such as pulso-prod, or pass -AllowAnyProfile if you are sure." }
    $true
}

function Resolve-BaseUrl {
    if ($script:Cfg.BaseUrl) {
        $u = $script:Cfg.BaseUrl.TrimEnd('/')
        if ($u -notmatch '^https://[A-Za-z0-9.-]+$') { throw "-BaseUrl must be https://<domain> with no path (got '$($script:Cfg.BaseUrl)')." }
        return $u
    }
    if (-not $script:Ctx.ProfileOk) { return '' }
    $q = "DistributionList.Items[?Comment=='$($script:Cfg.NamePrefix) hackathon edge'].DomainName | [0]"
    $r = Invoke-AwsCli @('cloudfront', 'list-distributions', '--query', $q, '--output', 'text')
    if ($r.Exit -ne 0 -or $r.Out -notmatch '^[A-Za-z0-9.-]+\.cloudfront\.net$') { return '' }
    "https://$($r.Out)"
}

function Resolve-Bucket {
    if ($script:Cfg.Bucket) { return $script:Cfg.Bucket }
    if (-not $script:Ctx.ProfileOk) { return '' }
    $r = Invoke-AwsCli @('sts', 'get-caller-identity', '--query', 'Account', '--output', 'text')
    if ($r.Exit -ne 0 -or $r.Out -notmatch '^\d{12}$') { return '' }
    "$($script:Cfg.NamePrefix)-data-$($r.Out)"
}

# ---------------------------------------------------------------------------------------------------------------------
# Checks that go through the CloudFront URL
# ---------------------------------------------------------------------------------------------------------------------
function Test-EdgeSpa {
    $id = 'edge-spa'
    if (-not $script:Ctx.Base) { Add-Result $id 'FAIL' 'no CloudFront URL: pass -BaseUrl https://<id>.cloudfront.net, or -Profile so the distribution is looked up (aws cloudfront list-distributions)'; return }
    $r = Invoke-Curl -Url "$($script:Ctx.Base)/" -TimeoutSec 20
    if ($r.Status -eq 0) { Add-Result $id 'FAIL' "no answer from $($script:Ctx.Base) ($($r.Error))"; return }
    if ($r.Status -eq 403) { Add-Result $id 'FAIL' 'HTTP 403: the origin refused the request (X-Origin-Verify mismatch, WAF, or the distribution still deploying)'; return }
    if ($r.Status -in 502, 503, 504) { Add-Result $id 'FAIL' "HTTP $($r.Status) from CloudFront: the platform host or its proxy is down (docker compose -p pulso ps on the platform host)"; return }
    if ($r.Status -ne 200) { Add-Result $id 'FAIL' "HTTP $($r.Status)"; return }
    if ($r.Body -notmatch '(?i)<!doctype html' -or $r.Body -notmatch '(?i)<script') { Add-Result $id 'FAIL' 'HTTP 200 but the body is not the SPA (no HTML document with a script): the web container or the proxy route is wrong'; return }
    Add-Result $id 'PASS' "HTTP 200, the SPA index ($($r.Body.Length) bytes) at $($script:Ctx.Base)"
}

function Test-PlatformHealth {
    $id = 'platform-health'
    if (-not $script:Ctx.Base) { Add-Result $id 'SKIP' 'no CloudFront URL'; return }
    $h = Invoke-Curl -Url "$($script:Ctx.Base)/api/v1/health" -TimeoutSec 20
    if ($h.Status -eq 0) { Add-Result $id 'FAIL' "/api/v1/health: no answer ($($h.Error))"; return }
    $hj = ConvertFrom-JsonSafe $h.Body
    $checks = Get-Prop $hj @('checks')
    $names = @(); $failing = @()
    if ($checks) { foreach ($p in $checks.PSObject.Properties) { $names += "$($p.Name)=$($p.Value)"; if ("$($p.Value)" -ne 'ok') { $failing += $p.Name } } }
    if ($h.Status -ne 200 -or $failing.Count -gt 0) {
        $why = if ($failing.Count) { "failing: $($failing -join ', ')" } else { "HTTP $($h.Status)" }
        Add-Result $id 'FAIL' "/api/v1/health $why (database ok and the Core reachable are both required here)"
        return
    }
    $m = Invoke-Curl -Url "$($script:Ctx.Base)/api/v1/meta" -TimeoutSec 20
    $mj = Get-Json $m
    $envName = Get-Prop $mj @('environment')
    if (-not $mj) { Add-Result $id 'FAIL' "/api/v1/meta: $(Get-FailureText $m)"; return }
    if ($envName -ne 'staging') { Add-Result $id 'FAIL' "environment is '$envName', not staging: the demo accounts and the dev MFA code only exist with CC_ENV=staging"; return }
    Add-Result $id 'PASS' "health ok ($($names -join ', ')); environment staging, version $(Get-Prop $mj @('version'))"
}

function Test-DemoLogin {
    $id = 'demo-login'
    if (-not $script:Ctx.Base) { Add-Result $id 'SKIP' 'no CloudFront URL'; return }
    $body = (@{ email = $script:Cfg.SupervisorEmail; password = $script:Cfg.DemoPassword } | ConvertTo-Json -Compress)
    $l = Invoke-Curl -Method POST -Url "$($script:Ctx.Base)/api/v1/auth/login" -Body $body -TimeoutSec 30
    $lj = Get-Json $l
    if (-not $lj) {
        $hint = if ($l.Status -eq 401) { ' (the seed did not run: docker compose -p pulso --profile seed run --rm support-platform-seed on the platform host)' } else { '' }
        Add-Result $id 'FAIL' "login $(Get-FailureText $l)$hint"; return
    }
    $challenge = Get-Prop $lj @('challengeId', 'challenge_id')
    if (-not $challenge) { Add-Result $id 'FAIL' 'login answered without a challengeId'; return }
    $mb = (@{ challengeId = $challenge; code = $script:Cfg.MfaCode } | ConvertTo-Json -Compress)
    $m = Invoke-Curl -Method POST -Url "$($script:Ctx.Base)/api/v1/auth/mfa" -Body $mb -TimeoutSec 30
    $mj = Get-Json $m
    $token = Get-Prop $mj @('token')
    if (-not $token) { Add-Result $id 'FAIL' "mfa $(Get-FailureText $m) (the dev code 000000 only works with CC_ENV=staging)"; return }
    $script:Tokens.Supervisor = $token
    $me = Invoke-Curl -Url "$($script:Ctx.Base)/api/v1/auth/me" -Token $token -TimeoutSec 20
    if ($me.Status -ne 200) { Add-Result $id 'FAIL' "session token refused by /auth/me: $(Get-FailureText $me)"; return }
    Add-Result $id 'PASS' 'supervisor logged in with password and the dev MFA code; session token accepted by /auth/me'
}

function Test-CustomerChat {
    $id = 'customer-chat'
    if (-not $script:Ctx.Base) { Add-Result $id 'SKIP' 'no CloudFront URL'; return }
    $base = $script:Ctx.Base
    $dc = Invoke-Curl -Url "$base/api/v1/customer/demo-customers" -TimeoutSec 20
    $dj = Get-Json $dc
    $items = @(Get-Prop $dj @('items'))
    if (-not $dj -or $items.Count -eq 0 -or -not $items[0]) { Add-Result $id 'FAIL' "no demo customers ($(if ($dj) { 'the list is empty: the seed did not run' } else { Get-FailureText $dc }))"; return }
    $customerId = Get-Prop $items[0] @('id')
    $s = Invoke-Curl -Method POST -Url "$base/api/v1/customer/sessions" -Body (@{ customerId = $customerId } | ConvertTo-Json -Compress) -TimeoutSec 30
    $sj = Get-Json $s
    $ctoken = Get-Prop $sj @('token')
    if (-not $ctoken) { Add-Result $id 'FAIL' "customer session $(Get-FailureText $s)"; return }
    $script:Tokens.Customer = $ctoken
    $mid = [guid]::NewGuid().ToString()
    $t = Invoke-Curl -Method POST -Url "$base/api/v1/customer/conversation/turns" -Token $ctoken -Headers @{ 'Idempotency-Key' = $mid } `
        -Body (@{ text = $script:Cfg.CustomerMessage; clientMessageId = $mid } | ConvertTo-Json -Compress) -TimeoutSec 60
    if ($t.Status -notin 200, 201) { Add-Result $id 'FAIL' "writing the customer turn $(Get-FailureText $t) (agent-core, the gateway or the JEV key can be the cause: check agent-core-ready)"; return }
    $started = Get-Date
    $deadline = $started.AddSeconds($script:Cfg.ChatWaitSeconds)
    $answer = $null
    while ((Get-Date) -lt $deadline) {
        $c = Invoke-Curl -Url "$base/api/v1/customer/conversation" -Token $ctoken -TimeoutSec 30
        $cj = Get-Json $c
        $turns = @(Get-Prop $cj @('turns'))
        $answer = $turns | Where-Object { $_ -and (Get-Prop $_ @('authorRole', 'author_role')) -eq 'assistant' } | Select-Object -First 1
        if ($answer) { break }
        Start-Sleep -Seconds 3
    }
    if (-not $answer) {
        Add-Result $id 'FAIL' "no assistant turn within ${ChatWaitSeconds}s: the platform did not get an answer from agent-core (check the AI switch, agent-core-ready, the gateway and the OpenRouter and JEV keys)"
        return
    }
    $secs = [int]((Get-Date) - $started).TotalSeconds
    Add-Result $id 'PASS' "customer turn accepted and the assistant answered in about ${secs}s (an agent-core run created through the platform)"
}

function Test-EngineEdge {
    $id = 'engine-edge'
    if (-not $script:Ctx.Base) { Add-Result $id 'SKIP' 'no CloudFront URL'; return }
    $r = Invoke-Curl -Url "$($script:Ctx.Base)/pulso/readyz" -TimeoutSec 20
    if ($r.Status -eq 200) { Add-Result $id 'PASS' 'HTTP 200 on /pulso/readyz (migrations applied, database answers, tasks alive)'; return }
    $detail = if ($r.Status -eq 503) { " $((ConvertFrom-JsonSafe $r.Body | ForEach-Object { Get-Prop $_ @('reason', 'status') }))" } else { '' }
    Add-Result $id 'FAIL' "/pulso/readyz $(Get-FailureText $r)$detail (engine host, proxy, or the database role switch of docs/infra-day-one.md layer 7)"
}

function Test-EngineAnnounce {
    $id = 'engine-announce'
    if (-not $script:Ctx.Base) { Add-Result $id 'SKIP' 'no CloudFront URL'; return }
    if (-not $script:Tokens.Supervisor) { Add-Result $id 'SKIP' 'no supervisor session (demo-login did not pass)'; return }
    $r = Invoke-Curl -Url "$($script:Ctx.Base)/api/v1/builder/proposals?limit=50" -Token $script:Tokens.Supervisor -TimeoutSec 60
    $j = Get-Json $r
    if (-not $j) { Add-Result $id 'FAIL' "GET /builder/proposals $(Get-FailureText $r) (404 assistant_disabled: the AI switch is off or agent-core is not configured)"; return }
    $items = @(Get-Prop $j @('items'))
    $mine = @($items | Where-Object { $_ -and (Get-Prop $_ @('source')) -eq 'engine' })
    if ($mine.Count -eq 0) {
        Add-Result $id 'FAIL' "the Automatizacion list has $($items.Count) proposal(s) and none with source engine: run the loop (sudo systemctl start pulso-loop) and read its journal; announce needs PULSO_ANNOUNCE_TO_PLATFORM=on"
        return
    }
    $first = $mine[0]
    Add-Result $id 'PASS' "$($mine.Count) proposal(s) with source engine in the Automatizacion list (latest: $(Get-Prop $first @('proposalId')) for agent $(Get-Prop $first @('agentId')), state $(Get-Prop $first @('state')))"
}

# ---------------------------------------------------------------------------------------------------------------------
# S3 checks (read only, with the operator's own profile)
# ---------------------------------------------------------------------------------------------------------------------
function Test-S3Ready([string]$Id) {
    if (-not $script:Ctx.ProfileOk) { Add-Result $Id 'SKIP' 'no -Profile: S3 checks need the operator profile (read-only calls)'; return $false }
    if (-not $script:Ctx.Bucket) { Add-Result $Id 'FAIL' 'cannot resolve the data bucket (sts get-caller-identity failed); pass -Bucket'; return $false }
    $true
}

function Test-S3Object([string]$Key) {
    (Invoke-AwsCli @('s3api', 'head-object', '--bucket', $script:Ctx.Bucket, '--key', $Key, '--query', 'ContentLength', '--output', 'text')).Exit -eq 0
}

function Test-LoaderMarker {
    $id = 'loader-marker'
    if (-not (Test-S3Ready $id)) { return }
    $b = $script:Ctx.Bucket
    if (-not (Test-S3Object 'engine/inbox/READY.json')) { Add-Result $id 'FAIL' "s3://$b/engine/inbox/READY.json is missing: upload landing/ and write the marker LAST (docs/auto-loader.md)"; return }
    $s = Invoke-AwsCli @('s3', 'cp', "s3://$b/engine/loader/status/last.json", '-')
    $sj = if ($s.Exit -eq 0) { ConvertFrom-JsonSafe $s.Out } else { $null }
    if (-not $sj) { Add-Result $id 'FAIL' 'marker present but the loader has not reported yet (engine/loader/status/last.json): is pulso-loader.timer active on the engine host? (systemctl list-timers pulso-loader.timer)'; return }
    $state = Get-Prop $sj @('state')
    if ($state -ne 'ok') { Add-Result $id 'FAIL' "loader state is '$state' (detail: $(Get-Prop $sj @('detail'))); journalctl -u pulso-loader on the engine host"; return }
    Add-Result $id 'PASS' "marker present and the loader reports state ok for run $(Get-Prop $sj @('run')) at $(Get-Prop $sj @('at'))"
}

function Test-LakeZones {
    $id = 'lake-zones'
    if (-not (Test-S3Ready $id)) { return }
    $b = $script:Ctx.Bucket
    $r = Invoke-AwsCli @('s3api', 'list-objects-v2', '--bucket', $b, '--prefix', 'lake/', '--delimiter', '/', '--query', 'CommonPrefixes[].Prefix', '--output', 'text')
    if ($r.Exit -ne 0) { Add-Result $id 'FAIL' "cannot list s3://$b/lake/ ($($r.Out -replace '\s+', ' '))"; return }
    $have = @($r.Out -split '\s+' | Where-Object { $_ })
    $want = @('lake/bronze/', 'lake/silver/', 'lake/gold_masked/', 'lake/gold_analytics/', 'lake/gold_restricted/', 'lake/publish/')
    $missing = @($want | Where-Object { $have -notcontains $_ })
    if ($missing.Count) { Add-Result $id 'FAIL' "lake zones missing: $($missing -join ', ') (the loader has not published; see loader-marker)"; return }
    if (-not (Test-S3Object 'lake/publish/latest.json')) { Add-Result $id 'FAIL' 'lake/publish/latest.json is missing: the publication pointer is written LAST by the pipeline'; return }
    $cells = if (Test-S3Object 'lake/gold_analytics/bank_cells/latest.json') { 'loader cells (lake/gold_analytics/bank_cells/latest.json)' }
    elseif (Test-S3Object 'engine/inputs/cells.ndjson') { 'operator cells (engine/inputs/cells.ndjson)' } else { '' }
    if (-not $cells) { Add-Result $id 'FAIL' 'zones and publication exist but there are no cells for the loop: neither lake/gold_analytics/bank_cells/latest.json nor engine/inputs/cells.ndjson'; return }
    Add-Result $id 'PASS' "zones bronze, silver, gold_masked, gold_analytics, gold_restricted, publish present; publication pointer present; loop input: $cells"
}

# ---------------------------------------------------------------------------------------------------------------------
# Host-side checks: exact commands, judged output
# ---------------------------------------------------------------------------------------------------------------------
$script:PyGet = 'python -c "import urllib.request as u; r=u.urlopen(''{0}'', timeout=4); print(''HTTP'', r.status, r.read().decode()[:200])"'
$script:Compose = 'sudo docker compose -p pulso --project-directory /srv/stack'

function Get-HostCheckDefinitions {
    @(
        [pscustomobject]@{ Id = 'agent-core-ready'; Workload = 'core'; What = 'agent-core serve /readyz (postgres, keys, schema, llm_gateway, tool_service)'
            Commands = @("curl -sS -m 5 -w '\nHTTP %{http_code}\n' http://127.0.0.1:8001/readyz"); Test = 'Test-AgentCoreReady' },
        [pscustomobject]@{ Id = 'gateway-ready'; Workload = 'core'; What = 'llm-gateway /healthz (liveness only: the binary has no readiness endpoint)'
            Commands = @("curl -sS -m 5 -w '\nHTTP %{http_code}\n' http://127.0.0.1:8080/healthz"); Test = 'Test-GatewayReady' },
        [pscustomobject]@{ Id = 'tool-service-ready'; Workload = 'core'; What = 'tool-service /readyz (200 only with a publication mounted)'
            Commands = @("$($script:Compose) exec -T tool-service python -c `"import urllib.request as u; print('HTTP', u.urlopen('http://127.0.0.1:8080/readyz', timeout=4).status)`""); Test = 'Test-ToolServiceReady' },
        [pscustomobject]@{ Id = 'engine-loop-check'; Workload = 'engine'; What = 'pulso loop --check (configuration, cells, regression proof, credential mode)'
            Commands = @("$($script:Compose) run --rm pulso-loop loop --check; echo EXIT=`$?"); Test = 'Test-LoopCheck' },
        [pscustomobject]@{ Id = 'engine-loop-unit'; Workload = 'engine'; What = 'systemctl status of pulso-loop and its timer, FAILED marker'
            Commands = @('systemctl is-active pulso-loop.timer', 'systemctl show pulso-loop -p ActiveState -p SubState -p Result -p ExecMainStatus -p ExecMainExitTimestamp',
                'systemctl status pulso-loop --no-pager -n 5 | head -n 12', 'if [ -e /srv/data/loop/FAILED ]; then echo FAILED_MARKER=present; else echo FAILED_MARKER=absent; fi'); Test = 'Test-LoopUnit' },
        [pscustomobject]@{ Id = 'forwarder'; Workload = 'core'; What = 'OTLP forwarder sidecars of the gateway and agent-core (core host)'
            Commands = @("$($script:Compose) exec -T otlp-forwarder-gateway $($script:PyGet -f 'http://127.0.0.1:4318/healthz')",
                "$($script:Compose) exec -T otlp-forwarder-agent $($script:PyGet -f 'http://127.0.0.1:4318/healthz')"); Test = 'Test-ForwarderCore' },
        [pscustomobject]@{ Id = 'forwarder-engine'; Workload = 'engine'; What = 'OTLP forwarder sidecar of the engine (engine host)'
            Commands = @("$($script:Compose) exec -T otlp-forwarder-engine $($script:PyGet -f 'http://127.0.0.1:4318/healthz')"); Test = 'Test-ForwarderEngine' }
    )
}

function Get-HttpStatuses([string]$Out) { @([regex]::Matches($Out, 'HTTP\s+(\d{3})') | ForEach-Object { [int]$_.Groups[1].Value }) }

function Test-AgentCoreReady([string]$Out) {
    $st = @(Get-HttpStatuses $Out)
    $j = ConvertFrom-JsonSafe (($Out -split "`n" | Where-Object { $_ -match '^\s*\{' } | Select-Object -First 1))
    $checks = Get-Prop $j @('checks')
    $bad = @(); $seen = @()
    if ($checks) { foreach ($p in $checks.PSObject.Properties) { $seen += "$($p.Name)=$($p.Value)"; if ("$($p.Value)" -ne 'ok') { $bad += "$($p.Name)=$($p.Value)" } } }
    if ($st.Count -eq 0 -or $st[0] -ne 200 -or $bad.Count -gt 0 -or -not $checks) {
        $why = if ($bad.Count) { $bad -join ', ' } elseif ($st.Count) { "HTTP $($st[0])" } else { 'no answer' }
        return [pscustomobject]@{ Ok = $false; Reason = "agent-core /readyz not ready: $why" }
    }
    [pscustomobject]@{ Ok = $true; Reason = "HTTP 200, status ready ($($seen -join ', '))" }
}

function Test-GatewayReady([string]$Out) {
    $st = @(Get-HttpStatuses $Out)
    if ($st.Count -and $st[0] -eq 200) { return [pscustomobject]@{ Ok = $true; Reason = 'HTTP 200 on /healthz (liveness: a bad provider key only shows as per-call errors, which customer-chat covers)' } }
    [pscustomobject]@{ Ok = $false; Reason = "gateway /healthz $(if ($st.Count) { "HTTP $($st[0])" } else { 'no answer' })" }
}

function Test-ToolServiceReady([string]$Out) {
    $st = @(Get-HttpStatuses $Out)
    if ($st.Count -and $st[0] -eq 200) { return [pscustomobject]@{ Ok = $true; Reason = 'HTTP 200 on /readyz (a publication is mounted)' } }
    [pscustomobject]@{ Ok = $false; Reason = 'tool-service /readyz is not 200 (503 until a publication is synced: after the loader published, restart pulso-stack on the core host)' }
}

function Test-LoopCheck([string]$Out) {
    $missing = @()
    if ($Out -notmatch '"cells_present"\s*:\s*true') { $missing += 'cells_present' }
    if ($Out -notmatch '"proof"\s*:\s*true') { $missing += 'proof (python and scripts/regression in the engine image)' }
    if ($Out -notmatch 'EXIT=0') { $missing += 'exit code 0' }
    if ($missing.Count) { return [pscustomobject]@{ Ok = $false; Reason = "pulso loop --check: not satisfied: $($missing -join ', ')" } }
    $mode = [regex]::Match($Out, '"auth_mode"\s*:\s*"([^"]{1,80})').Groups[1].Value
    [pscustomobject]@{ Ok = $true; Reason = "exit 0, cells_present true, proof true$(if ($mode) { ", auth_mode: $mode" })" }
}

function Test-LoopUnit([string]$Out) {
    $problems = @()
    if ($Out -notmatch '(?m)^active\s*$') { $problems += 'pulso-loop.timer is not active' }
    if ($Out -match 'FAILED_MARKER=present') { $problems += '/srv/data/loop/FAILED exists (the last run failed)' }
    if ($Out -notmatch '(?m)^Result=success') { $problems += 'Result is not success' }
    if ($Out -match '(?m)^ExecMainStatus=(\d+)' -and $Matches[1] -notin '0', '75') { $problems += "last exit status $($Matches[1])" }
    if ($Out -match '(?m)^ExecMainExitTimestamp=\s*$') { $problems += 'pulso-loop has not run yet (sudo systemctl start pulso-loop, then read journalctl -u pulso-loop)' }
    if ($problems.Count) { return [pscustomobject]@{ Ok = $false; Reason = ($problems -join '; ') } }
    [pscustomobject]@{ Ok = $true; Reason = 'timer active, last run Result=success, no FAILED marker' }
}

function Test-ForwarderOutput([string]$Out, [int]$Expected) {
    $n = @(Get-HttpStatuses $Out | Where-Object { $_ -eq 200 }).Count
    if ($n -ge $Expected) { return [pscustomobject]@{ Ok = $true; Reason = "$n forwarder sidecar(s) answered /healthz 200 (Langfuse keys: see aws-prod.ps1 status for LANGFUSE__ UNSET)" } }
    [pscustomobject]@{ Ok = $false; Reason = "$n of $Expected forwarder sidecar(s) answered 200 (is otlp_forwarder_enabled on and images forwarder deployed on that host?)" }
}
function Test-ForwarderCore([string]$Out) { Test-ForwarderOutput $Out 2 }
function Test-ForwarderEngine([string]$Out) { Test-ForwarderOutput $Out 1 }

function Get-WorkDir {
    $dir = if ($env:AWS_PROD_WORKDIR) { $env:AWS_PROD_WORKDIR } else { Join-Path (Split-Path $PSScriptRoot -Parent) '.scratch/aws-acceptance' }
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $dir
}

function Write-SsmDocument($Def) {
    $file = Join-Path (Get-WorkDir) "host-check-$($Def.Id).json"
    $doc = [ordered]@{ commands = @($Def.Commands); executionTimeout = @('120') }
    [IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    $file
}

function Get-SsmCommandText($Def, [string]$File) {
    $p = if ($script:Ctx.Profile) { $script:Ctx.Profile } else { '<profile>' }
    $f = 'file://' + ($File -replace '\\', '/')
    @(
        "# $($Def.Id) ($($Def.Workload) host): $($Def.What)",
        "aws ssm send-command --profile $p --region $($script:Region) --document-name AWS-RunShellScript --targets `"Key=tag:Workload,Values=$($Def.Workload)`" --parameters $f --query Command.CommandId --output text",
        "aws ssm list-command-invocations --profile $p --region $($script:Region) --command-id <CommandId from the line above> --details --query `"CommandInvocations[].CommandPlugins[].Output`" --output text"
    )
}

function Invoke-HostCommands($Def) {
    # Run mode: the same read-only commands, through SSM Run Command on the running instance with the Workload tag.
    $f = Invoke-AwsCli @('ec2', 'describe-instances', '--filters', "Name=tag:Workload,Values=$($Def.Workload)", 'Name=instance-state-name,Values=running', '--query', 'Reservations[].Instances[].InstanceId', '--output', 'text')
    $instance = ($f.Out -split '\s+' | Where-Object { $_ -match '^i-[0-9a-f]{8,17}$' } | Select-Object -First 1)
    if (-not $instance) { return [pscustomobject]@{ Ok = $false; Out = ''; Error = "no running instance with Workload=$($Def.Workload)" } }
    $file = Write-SsmDocument $Def
    $s = Invoke-AwsCli @('ssm', 'send-command', '--instance-ids', $instance, '--document-name', 'AWS-RunShellScript', '--parameters', ('file://' + ($file -replace '\\', '/')),
        '--comment', "pulso acceptance $($Def.Id)", '--query', 'Command.CommandId', '--output', 'text')
    if ($s.Exit -ne 0 -or $s.Out -notmatch '^[0-9a-f-]{20,40}$') { return [pscustomobject]@{ Ok = $false; Out = ''; Error = "send-command failed ($($s.Out -replace '\s+', ' '))" } }
    $status = ''
    for ($i = 0; $i -lt 60; $i++) {
        $g = Invoke-AwsCli @('ssm', 'get-command-invocation', '--command-id', $s.Out, '--instance-id', $instance, '--query', 'Status', '--output', 'text')
        $status = $g.Out
        if ($status -in 'Success', 'Failed', 'TimedOut', 'Cancelled', 'Cancelling') { break }
        Start-Sleep -Seconds 3
    }
    $o = Invoke-AwsCli @('ssm', 'get-command-invocation', '--command-id', $s.Out, '--instance-id', $instance, '--query', 'StandardOutputContent', '--output', 'text')
    [pscustomobject]@{ Ok = ($status -in 'Success', 'Failed'); Out = $o.Out; Error = $(if ($status -in 'Success', 'Failed') { '' } else { "command ended with status $status" }) }
}

function Test-HostChecks([string[]]$Ids) {
    foreach ($def in @(Get-HostCheckDefinitions | Where-Object { $Ids -contains $_.Id })) {
        # -Only forwarder covers both forwarder checks (core host and engine host).
        if (-not ((Test-Wanted $def.Id) -or ($def.Id -eq 'forwarder-engine' -and (Test-Wanted 'forwarder')))) { continue }
        if ($script:Cfg.HostChecks -eq 'Run') {
            if (-not $script:Ctx.ProfileOk) { Add-Result $def.Id 'SKIP' 'host-side check: -HostChecks Run needs -Profile'; continue }
            $r = Invoke-HostCommands $def
            if (-not $r.Ok) { Add-Result $def.Id 'FAIL' "host command: $($r.Error)"; continue }
            $verdict = & $def.Test $r.Out
            Add-Result $def.Id $(if ($verdict.Ok) { 'PASS' } else { 'FAIL' }) $verdict.Reason
        } else {
            $file = Write-SsmDocument $def
            foreach ($line in (Get-SsmCommandText $def $file)) { $script:HostPrinted.Add($line) }
            Add-Result $def.Id 'SKIP' "host-side: run the SSM command printed below (or rerun with -HostChecks Run); $($def.What)"
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------------------------------
function Invoke-Acceptance {
    $script:Results.Clear(); $script:HostPrinted.Clear()
    $script:Tokens = @{ Supervisor = ''; Customer = '' }
    $script:Ctx = @{ Base = ''; Profile = $script:Cfg.Profile; Bucket = ''; ProfileOk = $false }
    $script:Ctx.ProfileOk = Test-ProfileName $script:Cfg.Profile ([bool]$script:Cfg.AllowAnyProfile)
    $script:Ctx.Base = Resolve-BaseUrl
    $script:Ctx.Bucket = Resolve-Bucket

    Write-Host "Pulso AWS acceptance: URL $(if ($script:Ctx.Base) { $script:Ctx.Base } else { '(none)' }), profile $(if ($script:Cfg.Profile) { $script:Cfg.Profile } else { '(none)' }), host checks $($script:Cfg.HostChecks)"
    if (Test-Wanted 'edge-spa') { Test-EdgeSpa }
    if (Test-Wanted 'platform-health') { Test-PlatformHealth }
    # engine-announce needs the supervisor session, so demo-login runs (and reports) for it too.
    if ((Test-Wanted 'demo-login') -or (Test-Wanted 'engine-announce')) { Test-DemoLogin }
    if (Test-Wanted 'customer-chat') { Test-CustomerChat }
    Test-HostChecks @('agent-core-ready', 'gateway-ready', 'tool-service-ready')
    if (Test-Wanted 'loader-marker') { Test-LoaderMarker }
    if (Test-Wanted 'lake-zones') { Test-LakeZones }
    if (Test-Wanted 'engine-edge') { Test-EngineEdge }
    Test-HostChecks @('engine-loop-check', 'engine-loop-unit')
    if (Test-Wanted 'engine-announce') { Test-EngineAnnounce }
    Test-HostChecks @('forwarder', 'forwarder-engine')

    if ($script:HostPrinted.Count) {
        Write-Host ''
        Write-Host 'Host-side checks: run these (read-only) in this order, then read each output. Every command runs on the host as root through SSM.'
        foreach ($l in $script:HostPrinted) { Write-Host $l }
    }
    $pass = @($script:Results | Where-Object { $_.Status -eq 'PASS' }).Count
    $fail = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $skip = @($script:Results | Where-Object { $_.Status -eq 'SKIP' }).Count
    Write-Host ''
    Write-Host "Summary: $pass PASS, $fail FAIL, $skip SKIP$(if ($skip) { ' (a SKIP is not a pass: the system is accepted only when nothing is FAIL or SKIP)' })"
    if ($script:Cfg.ReportFile) { [IO.File]::WriteAllText($script:Cfg.ReportFile, ($script:Results | ConvertTo-Json -Depth 3), (New-Object Text.UTF8Encoding($false))) }
    if ($fail -gt 0) { return 1 }
    0
}

if ($LibraryOnly) { return }

try { $code = Invoke-Acceptance } catch { Write-Host "ERROR: $(Protect-Text $_.Exception.Message)"; exit 2 }
exit $code
