# Shipping a service change (for service teams)

Audience: the teams behind agent-core, llm-gateway, support-platform and the Pulso engine. You ship a change to YOUR service on the prod stack without a Terraform apply and without touching an instance. The infra owner (the human who runs the account) gives you an IAM identity once; after that everything below is one or two commands.

In short:

```powershell
# 1. build in the cloud (no local Docker needed) and get repo@sha256:...
.\scripts\aws-prod.ps1 images -Profile pulso-deploy-<team> -Service support-platform-api -SourceDir D:\src\support-platform
# 2. deploy that build; the host pulls it, restarts only what changed, waits for health, rolls back by itself on failure
.\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-<team> -Service support-platform-api -FromBuild <build id printed by step 1> -Wait
```

## Who owns what

| | Service team (you) | Infra owner |
|---|---|---|
| Code, Dockerfile, tests, image content | yes | no |
| Database schema and migrations of your service | yes | no (see the DB roles in [db-bootstrap](db-bootstrap.md)) |
| Build an image and deploy a new digest of your service | yes (this page) | no |
| Rolling back your service | yes | no |
| Environment variable NAMES your service reads | yes (document them in [secrets-keys](secrets-keys.md)) | no |
| Secret and config VALUES | asks | sets them (Secrets Manager, SSM) |
| Compose bundle (`deploy/hackathon/<workload>/`): memory limits, ports, health checks, new containers | proposes by pull request | reviews, applies |
| Terraform: instances, network, IAM, buckets, CloudFront, build projects | proposes by pull request | reviews, plans, applies |
| IAM users and roles for teams | asks | creates, attaches the deployer policy |

What the platform guarantees: images are pulled by digest (never a tag); a deploy never replaces an EC2 instance; the data volume, secrets and database are untouched by a deploy; if the new containers do not become healthy the host restores the previous digests by itself and the command fails.

## How it works

```
 your source dir
   -> aws-prod.ps1 images   zip (secrets excluded) -> s3://<bucket>/engine/build-src/<service>/<id>.zip
                            CodeBuild project pulso-prod-build-<service>: docker build, push to ECR
                            record {image, digest} -> s3://<bucket>/engine/build-out/<service>/<id>.json
   -> aws-prod.ps1 deploy   ECR check -> SSM parameter /pulso/<workload>/images/<key> = repo@sha256:...
                            SSM Run Command, document pulso-deploy-<workload>, target: instance tag Workload=<workload>
                            on the host: deploy-stack.sh = render env from SSM, compose pull, up -d, wait healthy
                            failure -> previous digests restored from /srv/stack/.deploy-state, command fails
```

- Digests live in SSM Parameter Store (String, free) at `/pulso/<workload>/images/<key>`. Terraform seeds them from `var.images` and then ignores their value (`ignore_changes`), so a later infra apply does not revert your deployment.
- The host start script resolves the digests from SSM every time `pulso-stack` starts, so a reboot or restart runs what you deployed.
- Changing a digest changes no Terraform-managed object: `user_data` and the AMI do not depend on digests (asserted in `terraform/modules/hackathon_compute/deploy.tftest.hcl` and, for the whole composition, in `terraform/envs/hackathon/hackathon.tftest.hcl`). The output `host_user_data_sha256` changes only when a start script changes, which is the one case where a plan would replace an instance.
- Modules: `modules/image_builder` (CodeBuild), `modules/hackathon_compute` (parameters, command document, `deploy-stack.sh` in the S3 bundle), `modules/deployer_policies` (your IAM policy). The build projects are wired by `module.image_builder` and the policies by `module.deployers` in `terraform/envs/hackathon/main.tf`; the repository names come from `var.ecr_repository_prefix` (default `pulso-prod`, the same prefix as the bootstrap).

| Service (`-Service`) | ECR repository | SSM key (`/pulso/<workload>/images/<key>`) | Host (workload) | Command document |
|---|---|---|---|---|
| `core-runtime` (alias `agent-core`) | `pulso-prod/core-runtime` | `core` | core | `pulso-deploy-core` |
| `llm-gateway` | `pulso-prod/llm-gateway` | `gateway` | core | `pulso-deploy-core` |
| `support-platform-api` | `pulso-prod/support-platform-api` | `support_api` | platform | `pulso-deploy-platform` |
| `support-platform-web` | `pulso-prod/support-platform-web` | `support_web` | platform | `pulso-deploy-platform` |
| `pulso-engine` (alias `engine`) | `pulso-prod/pulso-engine` | `pulso` | engine | `pulso-deploy-engine` |
| `caddy` (alias `proxy`, infra only) | `pulso-prod/caddy` | `proxy` | platform and engine | both documents |

The seven parameters: `/pulso/core/images/core`, `/pulso/core/images/gateway`, `/pulso/platform/images/support_api`, `/pulso/platform/images/support_web`, `/pulso/platform/images/proxy`, `/pulso/engine/images/pulso` and `/pulso/engine/images/proxy`. The `proxy` ones are the shared Caddy reverse proxy; only the infra owner changes them. Every host runs `docker compose -p pulso` from `/srv/stack`.

## IAM: what you need

The infra owner creates one IAM user (or role) per team and attaches the matching policy document. The documents are Terraform outputs of the prod composition, one per host:

| Team | Output (`terraform -chdir=terraform/envs/hackathon output -raw <name>`) |
|---|---|
| agent-core, llm-gateway | `deployer_policy_json_core` |
| support-platform | `deployer_policy_json_platform` |
| engine | `deployer_policy_json_engine` |

Infra owner, once per team (the policy JSON is the output; the console path is IAM > Policies > Create policy > JSON, then attach it to the user or role):

```powershell
terraform -chdir=terraform/envs/hackathon output -raw deployer_policy_json_platform > $env:TEMP\deployer-platform.json
# console: IAM > Policies > Create policy > JSON > paste > name it pulso-deployer-platform; IAM > Users > <team user> > Add permissions > attach it
Remove-Item $env:TEMP\deployer-platform.json
```

Team: create an access key for that user in the console (the infra owner hands it over through a safe channel, never in chat or Git), then `aws configure --profile pulso-deploy-<team>` (region `us-east-1`). Profile names `default`, `payana*`, `higo*`, `standar*` and `management*` are refused by the script.

What each policy allows, and nothing else (every statement is scoped to the services of that host; the test `terraform/modules/deployer_policies/deployer_policies.tftest.hcl` proves it):

| Statement | Allows | Scope |
|---|---|---|
| `EcrToken` | `ecr:GetAuthorizationToken` | all (AWS cannot scope it) |
| `EcrPushPull` | push, pull and describe images, no delete | the ECR repositories of your services |
| `WriteImageParameters`, `ReadImageParameters` | `ssm:PutParameter`; get, get history | `/pulso/<workload>/images/<key>` of your services, never the proxy, never config |
| `SendDeployDocument`, `SendDeployInstance` | `ssm:SendCommand` | only the document `pulso-deploy-<workload>`, only instances tagged `Workload=<workload>`; no `AWS-RunShellScript` |
| `ReadCommandResult` | `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations` | all (AWS cannot scope them) |
| `PutBuildSource`, `GetBuildOutput`, `ListBuildOutput`, `UseDataKey` | upload your source zip, read your build record | `engine/build-src/<service>/` and `engine/build-out/<service>/` of your services, and the bucket KMS key |
| `Build`, `ReadBuildLogs` | `codebuild:StartBuild`, `BatchGetBuilds`, read the logs | only the build projects of your services |

Never granted: IAM, EC2, Secrets Manager, RDS, other hosts, other teams' services, deleting images, changing config or secret values.

## Services

Common to all: the compose bundle in `deploy/hackathon/<workload>/compose.yaml` is the contract (memory limits leave 30 percent headroom on a t3.small, no published ports except the proxy and core-runtime 8000, `restart: unless-stopped`). The image must run as the user the bundle sets, read config only from environment variables, write only to its volumes and `/tmp`, and log to stdout.

### agent-core (`core-runtime`)

- Image: built from `core-bridge/Dockerfile` of the improvement-engine repository with the pinned agent-core checkout as the named build context `core` (`COPY --from=core`); the pin is in [ADR 0003](adr/0003-agent-core-workload.md). One image, three entrypoints chosen by the container command: `runtime` (the service, port 8000), `exporter` (no listener) and `migrate` (one-shot).
- Build: `-SourceDir` is the improvement-engine checkout, `-AgentCoreDir` the pinned agent-core checkout; the script stages it into the zip under `agent-core/` and the build runs `docker build -f core-bridge/Dockerfile --build-context core=agent-core core-bridge` (context `core-bridge/`). The staged copy of the agent-core `.dockerignore` has the `contracts` line removed, because the Dockerfile reads `contracts/VERSION`; your checkout is not modified.
  ```powershell
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-core -Service agent-core -SourceDir D:\src\improvement-engine -AgentCoreDir D:\src\agent-core
  ```
  If the Dockerfile lives elsewhere, pass `-Dockerfile <path inside the zip>`.
- Deploy: `.\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-core -Service core-runtime -FromBuild <build id> -Wait`.
- Config and secrets: secret keys `CORE__AGENTCORE_REGISTRY_DSN`, `CORE__AGENTCORE_EVAL_DSN`, `CORE__AGENTCORE_LLM_GATEWAY_TOKEN`, `CORE__PULSO_BRIDGE_CONTROL_SIGNER`, `CORE__PULSO_BRIDGE_LAB_SIGNER`; SSM `PULSO_LAB_BROKER_URL`, `PULSO_CONTROL_API_URL`, `PULSO_TENANT_ID`, `AGENTCORE_DAILY_BUDGET_USD`, `AGENTCORE_BLOB_BUCKET` (full list and naming in [secrets-keys](secrets-keys.md)).
- Health: `GET /readyz` on port 8000 (the compose health check). From the platform or engine host: `curl -s -o /dev/null -w "%{http_code}" http://core.pulso.internal:8000/readyz`.
- Database migration on upgrade: `core-migrate` runs the `migrate` entrypoint before `core-runtime` and `core-exporter` start (`depends_on: service_completed_successfully`). A new digest recreates all three, so migrations run on every upgrade; `deploy-stack.sh` counts the migrate container as healthy when it exited with code 0 and fails the deploy otherwise. Migrations must be backward compatible with the previous version (expand, then contract in a later release): a rollback restores the old image but NOT the old schema.

### llm-gateway

- Image: `Dockerfile` at the root of the llm-gateway repository (distroless: no shell, no curl).
  ```powershell
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-core -Service llm-gateway -SourceDir D:\src\llm-gateway
  .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-core -Service llm-gateway -FromBuild <build id> -Wait
  ```
- Published on 8080 for the engine host only (security group: engine); agent-core uses the docker network (`http://llm-gateway:8080`). `GET /healthz` on 8080. The compose health check is the image's own probe, `/llm-gateway -healthcheck` (liveness only); agent-core and core-runtime wait for it to be healthy.
- Config and secrets: `GATEWAY__GATEWAY_TOKEN_AGENT_CORE`, `GATEWAY__GATEWAY_TOKEN_ENGINE`, `GATEWAY__GATEWAY_TOKEN_SUPPORT_PLATFORM`, `GATEWAY__OPENAI_API_KEY`, `GATEWAY__ANTHROPIC_API_KEY`, `GATEWAY__GOOGLE_API_KEY`, `GATEWAY__JEV_API_KEY`; SSM `GATEWAY_CONSUMERS`, `LLM_ENDPOINTS`.

### agent-core serve (`agent-core-serve`, agent services only)

- Only with `agent_services_enabled` ([agent-services](agent-services.md)). Image: the `Dockerfile` at the root of the agent-core repository (`agentcore serve`), not `core-bridge`; the alias `agent-core` still means `core-runtime`.
  ```powershell
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-core -Service agent-core-serve -SourceDir D:\src\agent-core
  .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-core -Service agent-core-serve -FromBuild <build id> -Wait
  ```
- SSM key `/pulso/core/images/agent`; runs as `agent-core` on 8001 (`GET /healthz` liveness, `GET /readyz` readiness), after the one-shot `agent-core-migrate`; the environment contract is [agent-core-serve](agent-core-serve.md). Secrets `AGENT__*` and files `FILES__AGENT__*` ([agent-services](agent-services.md#secret-keys)).

### tool-service (`tool-service`, agent services only)

- Only with `agent_services_enabled`. Image: the `Dockerfile` at the root of the tool-service repository.
  ```powershell
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-core -Service tool-service -SourceDir D:\src\tool-service
  .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-core -Service tool-service -FromBuild <build id> -Wait
  ```
- SSM key `/pulso/core/images/tools`; published only on 8080 to the engine security group, reached by agent-core at `http://tool-service:8080` (`GET /healthz`, `GET /readyz` also checks the dataset). Reads the publication synced by the start script; secret `TOOLS__TOOL_SERVICE_TOKENS`.

### data-pipeline (`data-pipeline`, automatic loader only)

- Only with `auto_loader_enabled` ([auto-loader](auto-loader.md)). Image: the `Dockerfile` at the root of the data-pipeline repository (dbt + DuckDB, `ENTRYPOINT python -m pipeline.run`).
  ```powershell
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-engine -Service data-pipeline -SourceDir D:\src\data-pipeline
  .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-engine -Service data-pipeline -FromBuild <build id> -Wait
  ```
- SSM key `/pulso/engine/images/pipeline`; not a long-running service: the loader timer starts it per load.

### otlp-forwarder (`otlp-forwarder`, OTLP forwarder only)

- Only with `otlp_forwarder_enabled` ([otlp-forwarder](otlp-forwarder.md)). Image: the engine repository's `scripts/o11y` packaged by this repository's `docker/otlp-forwarder.Dockerfile`; `images -Service otlp-forwarder` adds that file to the source zip itself (unless the source already has it), so no `-Dockerfile` is needed.
  ```powershell
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-core -Service otlp-forwarder -SourceDir D:\src\improvement-engine
  .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-core -Service otlp-forwarder -FromBuild <build id> -Wait
  ```
- SSM keys `/pulso/core/images/forwarder` and `/pulso/engine/images/forwarder` (the same digest). Loopback sidecar of its producers, never published.

### support-platform (`support-platform-api`, `support-platform-web`)

- Two images, one host. API: `backend/Dockerfile` (context `backend/`), listens on 8000, health `GET /` (compose check), data in `/data` (the host path `/srv/data/support`). Web: `frontend/Dockerfile` (context `frontend/`), nginx on 80.
- `VITE_API_URL` is baked into the web bundle at BUILD time, so it must be passed when you build the web image and cannot be changed by a restart. Use the URL the browser reaches the API at (the CloudFront domain, which routes `/api/*` to the API); rebuild and redeploy the web image whenever it changes. `-ViteApiUrl` is accepted only for `support-platform-web` and is the same as `-BuildArg VITE_API_URL=...` (do not pass both).
  ```powershell
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-platform -Service support-platform-api -SourceDir D:\src\support-platform
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-platform -Service support-platform-web -SourceDir D:\src\support-platform -ViteApiUrl https://<cloudfront domain>
  .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-platform -Service support-platform-api -FromBuild <api build id> -Wait
  .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-platform -Service support-platform-web -FromBuild <web build id> -Wait
  ```
- Single-instance SQLite caveat: the API keeps SQLite on the host data volume, so there is exactly one API container. A deploy is stop-and-start (a few seconds of 502 from the proxy while the API restarts), not a rolling update; never scale it beyond one and never mount the volume elsewhere. The volume has daily snapshots (last 3). Moving to a shared database is a bundle change, proposed by pull request.
- Routes (Caddy): `/api/*` (including the WebSocket `/api/v1/ws`) to the API, everything else to the web container, `/internal*` answers 404.
- Config and secrets: `SUPPORT__CC_SESSION_SECRET`, `SUPPORT__CC_TOTP_SECRET_KEY`, `SUPPORT__CC_DATABASE_URL`; SSM `CC_CORS_ORIGINS`, `CC_PUBLIC_APP_URL`.
- Health: `https://<cloudfront domain>/healthz` (the proxy), `GET /` on the API.

### Pulso engine (`pulso-engine`)

- Image: the engine repository owns its Dockerfile. If the repository has none at its root, the script injects the template `docker/pulso.Dockerfile` of this repository. The binary must answer `pulso healthcheck` (probes `/healthz`) because the compose health check runs exactly that: `["CMD", "pulso", "healthcheck"]`.
  ```powershell
  .\scripts\aws-prod.ps1 images -Profile pulso-deploy-engine -Service engine -SourceDir D:\src\improvement-engine
  .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-engine -Service pulso-engine -FromBuild <build id> -Wait
  ```
- Runtime: command `run`, port 8080 behind the proxy at `/pulso/*`, state in `/var/lib/pulso` (host `/srv/data/pulso`), `stop_grace_period` 70 s (a deploy can take over a minute to stop the old container), reaches agent-core at `http://core.pulso.internal:8000`.
- Config and secrets: `PULSO__PULSO_DATABASE_URL`, `PULSO__PULSO_ADMIN_TOKEN`, `PULSO__PULSO_DEBUG_TOKEN`; SSM `PULSO_DATA_MODE`, `PIPELINE_ROOT`.
- Health: `https://<cloudfront domain>/pulso/healthz`, `pulso healthcheck` inside the container.

### Caddy proxy (`caddy`, infra owner only)

The platform and engine hosts front their services with a mirror of the upstream Caddy image (`pulso-prod/caddy`), pinned by digest. Mirroring is also done by CodeBuild (no zip: it pulls the image and pushes it to ECR): `.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service caddy -MirrorImage docker.io/library/caddy:<tag>`, then `deploy -Service caddy -FromBuild <id> -Wait` updates both hosts (platform first). Caddy configuration changes are bundle changes (pull request), not image changes.

## Build an image

### A. In the cloud (CodeBuild, the normal path)

Needs no Docker on your machine. Command: `.\scripts\aws-prod.ps1 images -Profile <profile> -Service <name> -SourceDir <dir>` with `-AgentCoreDir <dir>` for agent-core, `-Dockerfile <path in the zip>` to override the Dockerfile, `-BuildArg KEY=VALUE` (repeatable, no spaces or commas) for build arguments, `-MirrorImage <ref>` for `caddy`.

What it does, in order (it prints each step and the typed word `DEPLOY` is required first; `-Yes` skips the prompt for CI):

1. Zips the source directory. It never includes `.git`, `node_modules`, `target`, `.venv`, `.terraform`, any `.env` or `.env.*` (except `.env.example`), `*.pem`, `*.key`, `*.p12`, `*.pfx`, any file or directory with `credentials` in its name (except source code files `.py`, `.rs`, `.ts`, `.tsx`, `.js`, `.go`, so `credentials.py` is kept), `id_rsa*`, `id_ed25519*`, `*.tfstate`, `*.tfvars`, `.npmrc`, `.pypirc`, `.netrc`, `secrets.*` (same source-code exemption), `*.secret`; symbolic links are skipped. The list of excluded paths is printed before the upload so you can check that nothing you need is missing. Everything else is uploaded: review the printed summary.
2. Uploads the zip to `s3://<bucket>/engine/build-src/<service>/<id>.zip` (14-day lifecycle).
3. Starts the CodeBuild project `pulso-prod-build-<service>` (Linux x86_64, `BUILD_GENERAL1_MEDIUM`, 60 minute timeout, privileged Docker, default CodeBuild network, no secrets). It builds, pushes the tag `build-<id>` to ECR, reads the digest back from ECR and writes `{image, digest}` to `s3://<bucket>/engine/build-out/<service>/<id>.json` (14-day lifecycle). Tags in ECR are immutable; deployments always use the digest.
4. Waits, prints `IMAGE <registry>/pulso-prod/<repo>@sha256:...` and records it in the uncommitted `terraform/envs/hackathon/prod.tfvars` and in `.scratch/aws-prod/images-state.json`.

The build id is printed (format `<UTC timestamp>-<6 hex>`). A failed build prints its status and the log command (`aws logs tail /aws/codebuild/pulso-prod-build-<service> --since 2h`). The compute size is the infra variable `var.image_builder_compute_type`; the `pulso-engine` project (Rust release build inside `docker build`) is separate: `var.image_builder_engine_compute_type` (default `BUILD_GENERAL1_MEDIUM`, 7 GB) and a 120 minute timeout in every profile, so build it with `-BuildArg CARGO_BUILD_JOBS=4`; the whole builder can be switched off with `var.enable_image_builder`.

Docker Hub limits anonymous pulls per IP; if a `FROM` fails with `toomanyrequests`, retry later or pull your base images from an ECR mirror (ask the infra owner).

### B. Locally (podman or docker)

Use it when you must debug the build. The infra owner's podman machine may be too small for Rust or large Node builds; use path A then.

```powershell
aws ecr get-login-password --profile pulso-deploy-<team> --region us-east-1 | docker login --username AWS --password-stdin <account id>.dkr.ecr.us-east-1.amazonaws.com
docker build -f core-bridge/Dockerfile --build-context core=D:\src\agent-core -t <account id>.dkr.ecr.us-east-1.amazonaws.com/pulso-prod/core-runtime:build-local-1 D:\src\improvement-engine
docker push <account id>.dkr.ecr.us-east-1.amazonaws.com/pulso-prod/core-runtime:build-local-1
aws ecr describe-images --profile pulso-deploy-<team> --region us-east-1 --repository-name pulso-prod/core-runtime --image-ids imageTag=build-local-1 --query "imageDetails[0].imageDigest" --output text
```

Replace `docker` with `podman` if you use it. The tag must be unique (tags are immutable); the printed digest (`sha256:<64 hex>`) is what you deploy: `.\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-<team> -Service <name> -Digest sha256:<64 hex> -Wait`. The older all-in-one local flow (`.\scripts\aws-prod.ps1 images -PulsoDir ... -AgentCoreDir ... -LlmGatewayDir ... -SupportPlatformDir ... -CaddyUpstreamDigest ...`, without `-Service`) still exists for the infra owner's first bring-up; see the [quickstart](aws-prod-quickstart.md).

### C. First bring-up of an empty account (infra owner only)

The builder lives in the same Terraform composition as the hosts, and the hosts need image digests. For a brand-new account use the staged plan, which builds the network, the database, the bucket and the build projects with throw-away digests and no hosts:

```powershell
.\scripts\aws-prod.ps1 plan -Profile pulso-prod -Stage builder
.\scripts\aws-prod.ps1 apply -Profile pulso-prod
.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service caddy -MirrorImage docker.io/library/caddy:<tag>
```

Then `images -Service <name> ...` for each of the other five services, then the normal `plan` and `apply` (they read the digests from `prod.tfvars`). The hosts are created with real digests.

## Deploy

`.\scripts\aws-prod.ps1 deploy -Profile <profile> -Service <name> (-Digest sha256:<64 hex> | -FromBuild <build id> | -Rollback) [-Wait] [-Yes]`

Prints the plan and requires typing `DEPLOY` (or `-Yes`). Then, in this order: (1) with `-FromBuild`, reads the build record from S3; (2) checks that the digest exists in the ECR repository of the service; (3) reads the current value of `/pulso/<workload>/images/<key>`; (4) writes the new value (`ssm put-parameter`); (5) sends the document `pulso-deploy-<workload>` to the instance tagged `Workload=<workload>`; (6) with `-Wait`, polls until the command ends, prints the host output and the result.

On the host the document downloads the latest `deploy-stack.sh` from the bundle in S3 and runs it: renders the env from SSM and Secrets Manager (`pulso-stack-prepare`), `docker compose pull`, `docker compose up -d` (only containers whose image changed are recreated), then waits (up to 5 minutes, two consecutive passes) until every container is healthy, running without a health check, or a one-shot job exited with code 0. The last line is `DEPLOY_RESULT=ok`, `DEPLOY_RESULT=rolled_back` or `DEPLOY_RESULT=failed`.

Failure handling: if the new containers do not become healthy the host puts the previous digests back from `/srv/stack/.deploy-state/previous-images.env`, brings the stack up on them and exits non-zero; the script then also restores the previous value of the SSM parameter (so a reboot does not pull the bad digest) and exits non-zero with the reason. If `docker compose pull` fails (for example the digest is not pullable by the host role) nothing is touched.

Without `-Wait` the script returns right after sending the command and prints the command id; the failure restore of the SSM parameter only happens with `-Wait`. Use `-Wait` in CI.

## Verify

1. The command output with `-Wait` ends with `OK: <service> on <workload> runs <repo>@sha256:...`.
2. Health through the edge: `curl -s -o /dev/null -w "%{http_code}" https://<cloudfront domain>/healthz` (platform proxy) and `https://<cloudfront domain>/pulso/healthz` (engine). The domain is `terraform -chdir=terraform/envs/hackathon output cloudfront_domain_name` (ask the infra owner).
3. On the host (needs the Session Manager plugin and `ssm:StartSession`, which the deployer policies do not include: ask the infra owner or use the command output): `aws ssm start-session --profile pulso-prod --region us-east-1 --target <instance id>`, then `docker compose -p pulso ps`, `docker compose -p pulso logs --tail 100 <service>`, `sudo journalctl -u pulso-stack -b --no-pager`, `cat /srv/stack/.deploy-state/current-images.env`.
4. What SSM thinks is deployed: `aws ssm get-parameter --profile pulso-deploy-<team> --region us-east-1 --name /pulso/platform/images/support_api --query Parameter.Value --output text`.

## Roll back

`.\scripts\aws-prod.ps1 deploy -Profile <profile> -Service <name> -Rollback -Wait` takes the previous value from the history of the SSM parameter (the last value that differs from the current one), checks that its digest is still in ECR, and deploys it with the same guards. Or deploy a known-good digest explicitly with `-Digest`. Old digests stay in ECR. Rolling back code does not roll back a database schema (see agent-core above). A deploy that fails health rolls back by itself; you only roll back by hand for a bug that passes health.

## Change config or secrets of a service

- Names and conventions: secrets are keys `<SERVICE>__<VAR>` of the one Secrets Manager secret (`CORE__`, `GATEWAY__`, `SUPPORT__`, `PULSO__`, `COMMON__`); the host renders `<VAR>` into `/run/pulso/env/<service>.env`. Non-secret config is `/pulso/<workload>/<service>/<VAR>` in SSM. Catalogue: [secrets-keys](secrets-keys.md).
- You do not hold rights to change values. Ask the infra owner: say the key NAME, the host, and who sets the value (never put the value in chat or Git). A new key name needs a documented line in [secrets-keys](secrets-keys.md) and, if the compose file must pass it, a pull request on `deploy/hackathon/<workload>/compose.yaml`.
- Infra owner applies the change in Secrets Manager or SSM, then restarts the stack on the host so the env files are re-rendered: SSM session on the host, `sudo systemctl restart pulso-stack` (stops the stack, renders the env, starts it again with the digests from SSM; expect a short outage of that host).

## Request an infra change

For anything the deployer policy cannot do (new container, memory limit, port, health check, new service or repository, instance size, IAM, secrets plumbing):

1. Open a pull request (draft first) against `pulso-factored/infra`. Pick the place: compose and Caddy files in `deploy/hackathon/<workload>/`; per-host settings and image keys in `terraform/modules/hackathon_compute` and `terraform/envs/hackathon/variables.tf` (see the variable table in [modification-guide](modification-guide.md)); ECR repositories in `terraform/bootstrap` (`ecr_repositories`); builder in `modules/image_builder` and its `local.build_services` in `terraform/envs/hackathon/main.tf`; permissions in `modules/hackathon_iam` (hosts) or `modules/deployer_policies` (teams).
2. Tests first (strict red then green, small commits): a `terraform test` for the module you touch (mocked providers), `python -m unittest discover -s tests`, and the Pester tests in `scripts/tests` when the script changes. A changed doc must keep `tests/test_docs_consistency.py` and `tests/test_service_deployment_doc.py` green.
3. Run the offline plan-review checker before asking for review: `python scripts/aws_plan_review.py --validate` ([checklist](aws-plan-review-checklist.md)); it fails on public exposure, wildcard admin policies, hard-coded account ids and regions.
4. The infra owner reviews and applies from his machine (`.\scripts\aws-prod.ps1 plan`, read the summary, `.\scripts\aws-prod.ps1 apply`, type `APPLY`). CI never applies. Tell the reviewer whether `host_user_data_sha256` changes: that means an instance is replaced (data volume survives, short outage).

## Worked example: change one line in support-platform, ship, verify, roll back

Assume profile `pulso-deploy-platform`, the repository at `D:\src\support-platform`, and that the API answers `GET /` with a JSON greeting you want to change.

1. Edit the line, run your tests, commit. Nothing else is needed: no Dockerfile or infra change.
2. Build in the cloud:
   ```powershell
   .\scripts\aws-prod.ps1 images -Profile pulso-deploy-platform -Service support-platform-api -SourceDir D:\src\support-platform
   ```
   It prints the exclusion list (check that `.env` and `node_modules` are there), asks for `DEPLOY`, uploads, builds (a few minutes), and ends with `IMAGE <registry>/pulso-prod/support-platform-api@sha256:<64 hex>` and `Build id : 20261004153000-a1b2c3` (example). Remember the build id.
3. Deploy it:
   ```powershell
   .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-platform -Service support-platform-api -FromBuild 20261004153000-a1b2c3 -Wait
   ```
   Read the plan (parameter `/pulso/platform/images/support_api` from the old reference to the new one, document `pulso-deploy-platform`), type `DEPLOY`. The output lists `DEPLOYED SUPPORT_API_IMAGE=...`, `docker compose ps` and ends with `DEPLOY_RESULT=ok` then `OK: support-platform-api on platform runs ...`.
4. Verify: `curl -s https://<cloudfront domain>/api/` shows the new line; `curl -s -o /dev/null -w "%{http_code}" https://<cloudfront domain>/healthz` prints 200.
5. It is wrong in production? Roll back:
   ```powershell
   .\scripts\aws-prod.ps1 deploy -Profile pulso-deploy-platform -Service support-platform-api -Rollback -Wait
   ```
   The plan shows the current digest and the previous one; type `DEPLOY`. The host runs the previous image again and `curl` shows the old line.
6. If step 3 had failed health (for example the API crashed on start), the command would end with `DEPLOY_RESULT=rolled_back`, say that the host rolled back, restore the SSM parameter and exit non-zero: nothing to clean up, fix the code and start again at step 2.

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Refusing profile ...` | the profile name is `default`, `payana*`, `higo*`, `standar*` or `management*` | use a profile created for this account, such as `pulso-deploy-<team>` |
| `AccessDenied` on `s3 cp`, `codebuild start-build` or `ssm put-parameter` | the policy does not cover that service (for example the platform user building `pulso-engine`) or the policy is not attached | check the table in the IAM section; ask the infra owner |
| `images` aborts with `Aborted: you did not type DEPLOY` | typed something else | type exactly `DEPLOY`, or pass `-Yes` in CI |
| `images needs -SourceDir` / `-AgentCoreDir` / `-MirrorImage` | missing argument for that service | see the service section |
| Build ends `FAILED` | Dockerfile error, missing file (excluded?), Docker Hub rate limit, timeout (60 minutes) | `aws logs tail /aws/codebuild/pulso-prod-build-<service> --since 2h`; check the excluded list; ask for `var.image_builder_compute_type` larger |
| Build fails with `COPY --from=core` or a missing path | agent-core checkout not at `agent-core/` in the zip, or `-AgentCoreDir` missing | pass `-AgentCoreDir`; or override with `-Dockerfile` |
| `Digest ... not found in ECR` | wrong service or digest, or build for another service | copy the digest from the `IMAGE` line; check `-Service` |
| `unexpected image` in the build record | the record is not for that service | use the build id printed for that service |
| `deploy` returns but nothing changed | no `-Wait`, or the command is still running | `aws ssm list-command-invocations --command-id <id> --details` |
| `DEPLOY_RESULT=rolled_back` | new containers unhealthy (crash, wrong env, migration failed) | read the host output above it; `docker compose -p pulso logs` over SSM; fix and redeploy |
| `docker compose pull` fails on the host | the host role cannot pull the repository (new repository not in `var.images`), or ECR login failed | ask the infra owner; repository pull rights come from the image references in `var.images` |
| Command stays `InProgress` for long | health wait or stop grace (engine 70 s) | wait up to 15 minutes; the document times out at 900 s |
| `-Rollback`: `no previous value` | the parameter was never changed | deploy an explicit known-good `-Digest` |
| web shows calls to the wrong API URL | `VITE_API_URL` baked at build time is wrong | rebuild the web image with `-BuildArg VITE_API_URL=...` |
| Config change has no effect | env files are rendered at start | infra owner: `sudo systemctl restart pulso-stack` on that host |
| Infra plan wants to replace an instance | a start script (`user_data`) changed; digests never do | review the plan; see [operations](operations.md); only the infra owner applies |
