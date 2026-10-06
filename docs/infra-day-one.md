# Day one: from an empty AWS account to the full Pulso system

The ordered runbook for the COMPLETE profile ([prod.tfvars.complete.example](../terraform/envs/hackathon/prod.tfvars.complete.example)): platform (SPA and API) behind CloudFront on its own `*.cloudfront.net` domain, agent-core `serve` with its real pieces, llm-gateway, tool-service, the engine (`pulso run`, `pulso loop`, the loader and the data pipeline), one shared Postgres, the OTLP forwarder to Langfuse, all demo accounts, all seeds and both datasets (the bank dataset and E0). Every command below is run by the human; nothing here has been run against AWS, and every timing is an estimate (see [what is not verified](#what-is-not-verified)).

Read first if you want the reasons: [aws-prod-quickstart](aws-prod-quickstart.md) (one page), [deploy-readiness](deploy-readiness.md), [operations](operations.md), [edge-audit](edge-audit.md).

Legend. **HUMAN** marks a step only you can do: typing `APPLY`, `DEPLOY` or `SET`, pasting a provider key at a hidden prompt, choosing a value. **CHECK** is what must be true before the next layer. Commands are PowerShell 7 from the repository root, profile `pulso-prod`, region `us-east-1`. Placeholders in angle brackets (`<bucket>`, `<instance id>`) are values you read from the previous command.

## Inputs only the human provides

| Input | Where it goes | When |
|---|---|---|
| Typing `APPLY` (bootstrap, stack), `DEPLOY` (each image build), `SET` (each provider key), `SEED` (only if a secret pre-exists) | the prompt of `aws-prod.ps1` | layers 1 to 4 |
| OpenRouter API key | `aws-prod.ps1 set-secret -SecretKey GATEWAY__OPENROUTER_API_KEY`, hidden prompt | layer 5 |
| JEV API key (one value, fanned out to agent-core by the script) | `aws-prod.ps1 set-secret -SecretKey GATEWAY__JEV_API_KEY`, hidden prompt | layer 5 |
| Langfuse public and secret keys (OPTIONAL: without them the forwarders run but export nothing) | `aws-prod.ps1 set-secret -SecretKey LANGFUSE__LANGFUSE_PUBLIC_KEY` and `..._SECRET_KEY` | layer 5 |
| The upstream caddy image digest you choose to mirror (`sha256:<64 hex>`) | `-MirrorImage` | layer 3 |
| AWS CLI profile (root or admin access key, entered only with `aws configure`) | your machine | layer 0 |
| A two-minute admin credential for the agent registry seed, pasted at a hidden prompt on the core host | host shell | layer 10 |
| The READY marker that triggers the loader | `aws s3 cp` | layer 9 |

Nothing else is typed: every other secret (database passwords, DSNs, tokens, Ed25519 keys, TOTP and session secrets, the origin check, the pseudonymisation key) is generated and wired by Terraform ([human-secrets-only](human-secrets-only.md), [secrets-wiring](secrets-wiring.md)). Never paste a value in chat, a file or a command line.

## Expected time (estimates, unmeasured)

| Layer | Wall time | Mostly |
|---|---|---|
| 0 machine and account | 15 min | Defender exclusion, first provider download |
| 1 bootstrap | 5 min | first `terraform init` of the aws provider (minutes under Defender) |
| 2 network, data, builder | 10 min | apply |
| 3 images (ten builds) | 60 to 120 min | the engine Rust build (25 to 45 min on CodeBuild, unmeasured); the others 3 to 10 min each |
| 4 hosts and edge | 15 to 25 min | CloudFront distribution (5 to 15 min), instances |
| 5 to 8 start order, secrets, DB bootstrap | 30 min | image pulls, migrations, role switch |
| 9 data: upload, loader | 20 to 100 min | uploading about 5.0 GiB in about 7 700 small files (7 to 45 min by uplink), the loader (20 to 60 min, unmeasured, one hour STS limit) |
| 10 seeds | 15 min | |
| 11 first loop | 5 to 15 min | |
| 12 acceptance | 3 min | |
| Total | about 4 to 6 hours | waiting |

## Layer 0. Machine and account

1. Tools: PowerShell 7, Terraform 1.10 or newer, AWS CLI v2, Git, Python 3. No local Docker is needed: images are built in AWS.
2. Terraform on Windows, once ([troubleshooting](#troubleshooting-the-failures-already-met)): exclude the repository `terraform` folder, the Terraform plugin directory and `terraform.exe` from Windows Defender real-time scanning (administrator), and make sure `TF_PLUGIN_CACHE_DIR` is unset: `Remove-Item Env:TF_PLUGIN_CACHE_DIR -ErrorAction SilentlyContinue`. Run one terraform process at a time.
3. **HUMAN** create the access key in the console and enter it only here: `aws configure --profile pulso-prod` (region `us-east-1`).
4. Sources next to each other (paths are examples): `D:\src\improvement-engine` (engine, with [pull request 130](https://github.com/pulso-factored/improvement-engine/pull/130) merged: `main` alone lacks python and the regression scripts in the image, so `pulso loop` would exit 2), `D:\src\agent-core`, `D:\src\llm-gateway`, `D:\src\tool-service`, `D:\src\support-platform`, `D:\src\data-pipeline`.
5. Infra `main` must include the platform deploy-contract change (infra pull request 46, merged: `CC_ENV=staging` with the demo settings, the migrate one-shot, the seed unit, the `/readyz` health check, `X-Forwarded-Proto`, the 60 s origin read timeout); `git pull` before you start ([edge-audit](edge-audit.md), rows E1 to E5).
6. The profile: `Copy-Item terraform\envs\hackathon\prod.tfvars.complete.example terraform\envs\hackathon\prod.tfvars` (uncommitted, ignored by Git). Leave the digests as they are: `images` fills them.

```powershell
.\scripts\aws-prod.ps1 check -Profile pulso-prod
```

CHECK: the account id printed equals the console's.

## Layer 1. Bootstrap (state bucket and the ten ECR repositories)

```powershell
.\scripts\aws-prod.ps1 bootstrap-plan -Profile pulso-prod
.\scripts\aws-prod.ps1 bootstrap-apply -Profile pulso-prod     # HUMAN: read the summary, type APPLY
```

CHECK: `aws ecr describe-repositories --profile pulso-prod --region us-east-1 --query "repositories[].repositoryName" --output text` lists `pulso-prod/pulso-engine`, `core-runtime`, `llm-gateway`, `support-platform-api`, `support-platform-web`, `caddy`, `agent-core-serve`, `tool-service`, `data-pipeline`, `otlp-forwarder`. The state bucket is `pulso-prod-tfstate-<account id>`.

## Layer 2. Network, data and the CodeBuild builder (no hosts yet)

There is no local Docker, so the images are built by CodeBuild. A brand-new account builds them before the hosts exist, with throw-away digests only for planning:

```powershell
.\scripts\aws-prod.ps1 plan -Profile pulso-prod -Stage builder
.\scripts\aws-prod.ps1 apply -Profile pulso-prod               # HUMAN: type APPLY
```

The stage creates the network, the data bucket, the KMS key, the one secret with its generated keys, the roles and one build project per image (the complete profile turns on the loader and the forwarder, so `data-pipeline` and `otlp-forwarder` get projects too). CHECK: `.\scripts\aws-prod.ps1 status -Profile pulso-prod` prints the secret with the human keys UNSET and no wired key UNSET (there are no instances yet, so no host lines). If a wired key shows UNSET on a secret that pre-existed, run `.\scripts\aws-prod.ps1 seed-secret-keys -Profile pulso-prod` (**HUMAN**: `SEED`).

## Layer 3. Images (ten builds in CodeBuild)

One command per image; each uploads a source zip (never `.git`, `node_modules`, `target`, keys, `.env`), runs CodeBuild, waits, prints the `repo@sha256` digest and writes it into `prod.tfvars` (**HUMAN**: type `DEPLOY` at each prompt; `-Yes` skips only that prompt). The script keeps the digests of the images already built when it writes the next one.

```powershell
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service llm-gateway       -SourceDir D:\src\llm-gateway
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service tool-service      -SourceDir D:\src\tool-service
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service agent-core-serve  -SourceDir D:\src\agent-core
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service caddy             -MirrorImage docker.io/library/caddy@sha256:<digest you choose>
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service support-platform-api -SourceDir D:\src\support-platform
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service support-platform-web -SourceDir D:\src\support-platform -ViteApiUrl /
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service data-pipeline     -SourceDir D:\src\data-pipeline
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service otlp-forwarder    -SourceDir D:\src\improvement-engine
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service pulso-engine      -SourceDir D:\src\improvement-engine
```

| Image (ECR repository) | Built from | Slot in `prod.tfvars` | Notes |
|---|---|---|---|
| `llm-gateway` | the gateway repo `Dockerfile` | `images.core.gateway` | static Go binary, small |
| `tool-service` | its repo `Dockerfile` | `images.core.tools` | |
| `agent-core-serve` | agent-core's own `Dockerfile` (`agentcore serve`) | `images.core.agent` | the legacy `core-runtime` image is NOT built |
| `caddy` | a mirror of the upstream image you pin | `images.platform.proxy` and `images.engine.proxy` (one digest) | `-MirrorImage` takes the digest |
| `support-platform-api` | `backend/Dockerfile` | `images.platform.support_api` | |
| `support-platform-web` | `frontend/Dockerfile` with `VITE_API_URL=/` | `images.platform.support_web` | `-ViteApiUrl /` is the same-origin build; without it the SPA calls `http://localhost:8000` and nothing works ([edge-audit](edge-audit.md#what-the-platform-needs-for-same-origin-spa-calls)) |
| `data-pipeline` | its repo `Dockerfile` (dbt and DuckDB) | `images.engine.pipeline` | |
| `otlp-forwarder` | the engine repo `scripts/o11y`, packaged by this repository's `docker/otlp-forwarder.Dockerfile` (added to the zip by the script) | `images.core.forwarder` and `images.engine.forwarder` (one digest) | |
| `pulso-engine` | the engine repo `Dockerfile` (Rust, console, python3 and the regression scripts) | `images.engine.pulso` | the longest build; see below |

If the engine build ends `FAILED` with `Killed` or exit 137 (CodeBuild SMALL has 3 GB), build it on the core host after layer 4 instead: `-Builder host` (same command plus `-Builder host`, then `deploy -Service pulso-engine -FromBuild <build id> -Wait`). Until then `prod.tfvars` keeps a placeholder for `pulso` and `plan` refuses it, so do layer 4 only when it is built or temporarily pin it to any existing digest and `deploy` the real one afterwards.

CHECK: `Select-String -Path terraform\envs\hackathon\prod.tfvars -Pattern 'REPLACE_WITH|<registry>'` finds nothing; every slot of the table above holds `@sha256:` with 64 hex digits; the repositories hold the images (`aws ecr list-images --repository-name pulso-prod/agent-core-serve --profile pulso-prod --region us-east-1`).

## Layer 4. The hosts and the edge (one apply)

```powershell
.\scripts\aws-prod.ps1 plan -Profile pulso-prod
.\scripts\aws-prod.ps1 apply -Profile pulso-prod               # HUMAN: read the plan summary, type APPLY
```

Before typing `APPLY`, run the offline plan review ([aws-plan-review-checklist](aws-plan-review-checklist.md)). The apply creates three `m7i-flex.large` hosts (core, platform, engine) with their data volumes, the Postgres volume, the loader role, the SSM parameters and the CloudFront distribution. If AWS refuses a service on a Free Plan account, read the message literally ([troubleshooting](troubleshooting.md#free-plan-errors-at-apply)): a refusal costs one step. Each host starts `pulso-stack` by itself on first boot.

CHECK: `.\scripts\aws-prod.ps1 status -Profile pulso-prod` lists three running instances; the CloudFront domain is `terraform -chdir=terraform/envs/hackathon output -raw cloudfront_domain_name`. The site will not answer yet: the provider keys are still `CHANGE_ME` and the databases are not bootstrapped.

## Layer 5. Provider keys (HUMAN)

```powershell
.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey GATEWAY__OPENROUTER_API_KEY     # hidden prompt, then type SET
.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey GATEWAY__JEV_API_KEY            # also fills the agent-core copy
.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey LANGFUSE__LANGFUSE_PUBLIC_KEY   # optional
.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey LANGFUSE__LANGFUSE_SECRET_KEY   # optional
.\scripts\aws-prod.ps1 status -Profile pulso-prod
```

CHECK: `status` lists no human key UNSET (apart from the optional Langfuse ones) and no wired key UNSET. Hosts read a new value at their next `pulso-stack` start, which layers 6 to 8 do.

## Layer 6. Core host (agent-core, gateway, tool-service, Postgres)

Shell: `aws ssm start-session --profile pulso-prod --region us-east-1 --target <core instance id>` (ids from `status`).

```bash
sudo systemctl restart pulso-stack          # picks up the keys; Postgres initdb already ran on first boot with generated passwords
sudo docker compose -p pulso --project-directory /srv/stack ps
```

Wait until `postgres`, `llm-gateway`, `tool-service` and `agent-core` are `healthy` and `agent-core-migrate` and `core-migrate` exited 0 (2 to 5 minutes). CHECK: `curl -s http://127.0.0.1:8001/readyz` answers `ready` with postgres, keys, schema, llm_gateway and tool_service `ok`. `tool_service` may say `degraded` until a publication exists (layer 9): that is expected here. Order inside the host and the budget are in [run-and-health](run-and-health.md); the shared Postgres in [shared-postgres](shared-postgres.md).

The platform and tools databases come from the first-boot initdb when the passwords were in the secret before the first start (they are: they are generated at layer 2). If `docker compose ... exec postgres psql -U pulso_master -d postgres -c '\l'` lacks `platform` and `tools` (an older volume), run once `25_platform_databases.sql` as in [shared-postgres](shared-postgres.md#create-the-databases).

## Layer 7. Platform host

Only after the core host is healthy. Shell on the platform instance:

```bash
sudo systemctl restart pulso-stack          # also re-reads CC_PUBLIC_APP_URL and CC_CORS_ORIGINS, which exist only after the distribution
sudo docker compose -p pulso --project-directory /srv/stack ps
curl -s http://127.0.0.1:8000/readyz        # the API: database ok, Core ok or degraded
```

The restart matters on a first apply: the parameters of the public URL are written after the host exists ([edge-audit](edge-audit.md), row E11). The schema is created by the one-shot `support-platform-migrate` (owner role) that runs before the API starts (it exits 0 in `ps -a`). Then, once, the exporter grants for the engine's read-only role ([shared-postgres](shared-postgres.md#create-the-databases)), on the CORE host

```bash
sudo docker compose -p pulso --project-directory /srv/stack exec postgres psql -v ON_ERROR_STOP=1 -U pulso_master -d platform -f /docker-entrypoint-initdb.d/sql/26_platform_exporter_grants.sql
```

CHECK from your machine: `curl.exe -s -o NUL -w "%{http_code}" https://<domain>/` is 200 and `https://<domain>/api/v1/health` answers `ok` (the SPA through the edge and the API through the same origin).

## Layer 8. Engine host and the engine database bootstrap

```bash
sudo systemctl restart pulso-stack
sudo docker compose -p pulso --project-directory /srv/stack ps          # pulso healthy (migrations apply on its first start)
```

Database role bootstrap, in this order ([run-and-health](run-and-health.md), section 6.2): the first start uses the master role as the engine DSN so the engine can create its own roles; then on the CORE host redeploy or restart (`sudo systemctl restart pulso-stack`) so `pulso-db-bootstrap` runs and prints `logins enabled`. Switching the engine DSN to `pulso_app` is an optional hardening, not needed for the demo.

CHECK: `curl -s https://<domain>/pulso/readyz` is 200 from your machine (engine through the edge) and `pulso loop --check` is not run yet (cells arrive in layer 9).

## Layer 9. Data: upload, loader, publication

Order, always: landing upload, then the READY marker LAST, then the loader, then the core stack restart, then the engine cells. Details of the loader: [auto-loader](auto-loader.md).

What is uploaded (names and formats, from the data-pipeline repository; raw data is never read or copied by this runbook):

| Dataset | On your machine (example) | Layout the pipeline expects | Size | S3 target |
|---|---|---|---|---|
| Bank | `D:\.codex\factored\data` | 13 tables as CSV: six reference files at the root (`customers.csv`, `products.csv`, `branches.csv`, `service_agents.csv`, `marketing_campaigns.csv`, `daily_exchange_rates.csv`) and seven partitioned tables `<table>/year=YYYY/month=MM/day=DD/<table>_YYYYMMDD.csv` (`call_center_interactions`, `call_transcripts`, `campaign_sends`, `complaints`, `digital_events`, `satisfaction_surveys`, `transactions`) | about 5.0 GiB, about 7 700 files | `landing/bank/` |
| E0 sample | `D:\.codex\factored\pulso_muestra_e0` | the package root: `datos/*.parquet` (eleven tables, `labels` and `timeline` among them: the evaluator zone is separated by the pipeline and the bucket), `contratos/platform_history.json`, docs | about 4 MiB | `landing/e0/` |

```powershell
.\scripts\aws-prod.ps1 upload -Profile pulso-prod -Path D:\.codex\factored\data -Dataset bank -DryRun
.\scripts\aws-prod.ps1 upload -Profile pulso-prod -Path D:\.codex\factored\data -Dataset bank
.\scripts\aws-prod.ps1 upload -Profile pulso-prod -Path D:\.codex\factored\pulso_muestra_e0 -Dataset e0
```

`upload` is `aws s3 sync` with SSE-KMS (the bank upload keeps the `year=.../month=.../day=...` keys; the loader strips the prefix `landing/bank/` and takes the first path segment as the table, so do not nest another folder inside). Then the marker, last. Its content decides the run: changing a checksum triggers a new load, identical bytes never reload.

```powershell
$bucket = terraform -chdir=terraform/envs/hackathon output -raw bucket_name
$sums = [ordered]@{}
foreach ($f in 'customers.csv', 'products.csv') { $sums["landing/bank/$f"] = (Get-FileHash "D:\.codex\factored\data\$f" -Algorithm SHA256).Hash.ToLower() }
[ordered]@{ dataset = 'bank'; e0_prefix = 'landing/e0/'; files = $sums } | ConvertTo-Json -Depth 4 | Set-Content "$env:TEMP\READY.json" -Encoding ascii
aws s3 cp "$env:TEMP\READY.json" "s3://$bucket/engine/inbox/READY.json" --profile pulso-prod --region us-east-1     # HUMAN: this starts the load
```

Within 5 minutes `pulso-loader.timer` on the engine host picks it up: assume the loader role, `ingest_bank`, `ingest_e0`, dbt build, publish (`lake/publish/<run>/`, `latest.json` last). CHECK, from your machine: `aws s3 cp s3://<bucket>/engine/loader/status/last.json - --profile pulso-prod --region us-east-1` shows `"state":"ok"` (a run in progress shows `running`; on the host `journalctl -u pulso-loader -n 100 --no-pager`). The one-hour STS session is a hard limit on the run; a longer run fails and is re-run.

Then, in this order:

1. **tool-service download.** On the CORE host `sudo systemctl restart pulso-stack`: the start script copies `gold_restricted.duckdb` and `field_classification.json` of the current publication to `/srv/data/tools/data/publish`; tool-service answers `data_unavailable` until then. CHECK: tool-service `/readyz` is 200 (the acceptance script's `tool-service-ready`).
2. **Engine cells.** The loop reads `cells.ndjson` from the inputs mirror. The loader's own cells export is empty by default (`loader_cells_cmd` is empty: the producer is `scripts/aggregate/bank_cells.py` of the engine repo and is not in the pipeline image), so produce the aggregate cells on your machine and upload them, after the same k-anonymity gate the host re-runs:

```powershell
python D:\src\improvement-engine\scripts\aggregate\bank_cells.py --data-root D:\.codex\factored\data --out $env:TEMP\cells.ndjson
python deploy\hackathon\engine\loader\check_cells_k.py $env:TEMP\cells.ndjson
aws s3 cp "$env:TEMP\cells.ndjson" "s3://$bucket/engine/inputs/cells.ndjson" --sse aws:kms --profile pulso-prod --region us-east-1
```

The cells hold counts only (no identifiers, no text, every count 0 or at least 10). `pulso-inputs-sync` mirrors `engine/inputs/` before every loop run.

Size and time of the data path (estimates, unmeasured): upload 7 to 45 minutes; the loader 20 to 60 minutes (the pipeline README measured a full build of 13 tables in about 6 minutes on a laptop with one dbt thread, ingest from S3 and the 2 vCPU host come on top); the published lake is a few GiB of zstd parquet; the core volume (30 GB) holds the tool-service copy.

## Layer 10. Seeds

1. **Platform demo data.** The API seeds the demo accounts at its start (`CC_SEED_DEMO_DATA`). The full volume seed (many cases, activity) is a one-shot, once, after the migration, on the platform host: `sudo docker compose -p pulso --project-directory /srv/stack --profile seed run --rm support-platform-seed`. The accounts (Lucia Herrera and the other demo staff, password `demo1234`, dev MFA code `000000`) exist only with `CC_ENV=staging`; the acceptance script's `demo-login` and `platform-health` verify exactly that.
2. **Calibrations and classifiers** (agent-core artifacts, data-team output), then restart the core stack: [agent-services](agent-services.md#calibration-and-classifier-artifacts). Without them every decision stays below threshold.
3. **Agent registry seed** (the agents themselves; **HUMAN** pastes a two-minute admin credential at a hidden prompt): [agent-services](agent-services.md#loading-the-agents-registry-seed).

CHECK: the three flows of agent-core (`recepcion`, `disputas`, `consultas`, `copiloto-asesor` per `agent_serve_agents`) answer through the platform: the acceptance script's `customer-chat`.

## Layer 11. First improvement loop

On the engine host (the timer also runs it every 6 hours, first 10 minutes after boot):

```bash
sudo docker compose -p pulso --project-directory /srv/stack run --rm pulso-loop loop --check      # exit 0, cells_present true, proof true
sudo systemctl start pulso-loop
journalctl -u pulso-loop -n 100 --no-pager
systemctl status pulso-loop --no-pager
```

Exit status meanings and the FAILED marker: [engine-loop](engine-loop.md). A proposal is announced to the platform and appears in the supervisor's Automatizacion list (`/supervision/automation/proposals`, source engine). The engine never approves, publishes or promotes; a human with a step-up code does ([agent-core-serve](agent-core-serve.md)).

## Layer 12. Acceptance

```powershell
.\scripts\aws-acceptance.ps1 -Profile pulso-prod                     # platform and S3 checks here, SSM commands printed for the host-side ones
.\scripts\aws-acceptance.ps1 -Profile pulso-prod -HostChecks Run     # sends the same read-only commands through SSM and judges them
```

It prints PASS, FAIL or SKIP with the reason for each check, in this order: CloudFront and the SPA, the platform health through the edge, a demo supervisor login with the dev MFA code (API calls, no browser), a customer simulator chat that reaches the assistant (an agent-core run created through the platform), agent-core readiness, gateway and tool-service readiness (host-side), the loader marker and the lake zones (read-only S3), the engine through the edge, `pulso loop --check` and the loop unit (host-side), the engine's proposal in the Automatizacion list, and the forwarder sidecars. The exit code is non-zero when any check FAILs; a SKIP is not a pass. No secret is printed or logged: tokens live in memory and go to curl on its standard input. `-BaseUrl https://<domain>` skips the CloudFront lookup; `-Only <ids>` runs part of it; `-ReportFile <path>` writes the results as JSON. Tests: `scripts/tests/aws-acceptance.Tests.ps1` (Pester, mocked curl and aws).

Open the same URL in a browser as a last look: the SPA loads from the CloudFront domain and the network tab shows `/api/v1/...` on the same domain (not `localhost:8000`).

## Troubleshooting: the failures already met

| Symptom | Cause | Fix |
|---|---|---|
| `terraform init`, `plan` or `validate` hangs, "timeout while waiting for plugin to start" | the aws provider binary is large and Windows Defender scans it on every start (minutes) | add the repository `terraform` folder, the plugin directory and `terraform.exe` to the Defender exclusions (administrator); run `Remove-Item Env:TF_PLUGIN_CACHE_DIR` (it must be unset); one terraform process at a time; wait up to about 10 minutes before killing a first run |
| Local Podman rehearsal (`scripts/prodlike`): `controller pids is not available`, containers do not start through compose | the `pulso-dev` machine's crun cannot enforce the default pids limit | `up --podman-run` (the documented fallback, `--pids-limit=0`); not an AWS issue ([prodlike-rehearsal](prodlike-rehearsal.md)) |
| the SPA loads but every API call goes to `http://localhost:8000` (network errors, login does nothing) | the web image was built with the default `VITE_API_URL` | rebuild with `-ViteApiUrl /`, `deploy -Service support-platform-web -FromBuild <build id> -Wait`, hard-reload |
| platform API exits at start, restarts forever, `CC_PUBLIC_APP_URL` missing | the SSM parameters of the public URL are created after the host and the host read its env before | `sudo systemctl restart pulso-stack` on the platform host after the apply ([edge-audit](edge-audit.md), row E11) |
| Postgres init refuses to start: `CHANGE_ME` password | the secret held placeholders when the empty volume was first started | `seed-secret-keys` (merge only) before the first core start; never `terraform apply -replace` the secret version (it resets every out-of-band key) |
| `platform` or `tools` database missing; platform migration cannot connect | initdb runs only on an empty volume | run `25_platform_databases.sql` once as in [shared-postgres](shared-postgres.md#create-the-databases), then the exporter grants after the platform's first migration |
| engine `/pulso/readyz` stays 503 `db_unreachable` or the `pulso_*` roles are missing | the engine creates its roles at its first start; `pulso-db-bootstrap` only enables their logins afterwards | start the engine first, then restart the core stack; the DSN stays the master role for the demo ([run-and-health](run-and-health.md)) |
| tool-service `data_unavailable`, `/readyz` 503 | no publication synced: the core start script copies it only at stack start | after the loader published, `sudo systemctl restart pulso-stack` on the core host |
| loader finished `ok` but nothing was ingested | the dataset prefix lacked a trailing slash (fixed: the loader now normalises it), or the files are not under `landing/bank/<table>/...` | upload with `-Dataset bank` from the dataset root; list `aws s3 ls s3://<bucket>/landing/bank/ --profile pulso-prod` |
| `pulso loop` exits 2: "the regression proof needs Python" | the engine image built from `main` before pull request 130 has no python3 or scripts | rebuild `pulso-engine` from the merged engine `main` |
| `images` for one service made another service's digest disappear from `prod.tfvars` | older `aws-prod.ps1` rewrote the images block with six keys | fixed: `agent`, `tools`, `pipeline`, `forwarder` are kept; check the file after each build |
| `plan` says `prod.tfvars` still has placeholders | an image of the table in layer 3 is not built yet | build it; no placeholder may remain |
| `FAILED` CodeBuild, `Killed` or exit 137 on the engine | SMALL compute (3 GB) out of memory in the Rust release build | `-Builder host` after layer 4, or a larger `image_builder_compute_type` |
| CloudFront 502 or 504 | host or proxy down; or a request over 60 s (a slow agent-core turn) | `docker compose -p pulso ps` on the host; [edge-audit](edge-audit.md) rows E1 and E2 |
| CloudFront 403 | the origin refused the request: `X-Origin-Verify` mismatch (another distribution) or the distribution is still deploying | wait for the deployment; check the platform proxy |
| `demo-login` FAILs 401 or MFA invalid | the platform is not in `staging` mode or the seed did not run | `/api/v1/meta` must say `staging`; run the seed (layer 10) |
| a host does not come up, no SSM session | see [troubleshooting](troubleshooting.md#host-does-not-come-up) | |

## What is not verified

Nothing here ran against AWS: no apply, no image build, no host start, no acceptance run. The Python contract tests, the Pester tests of the acceptance script (mocked curl and aws) and the documentation checks run offline; Terraform tests were not run in this change. Timings and sizes are estimates, the loader and the Rust build on CodeBuild have never been measured, and the CloudFront behaviour of the WebSocket is documented by the platform team, not exercised.
