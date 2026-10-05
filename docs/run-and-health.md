# Run and health contract of the host stacks

How the three EC2 hosts run every service: image, command, environment names, ports, volumes, probes, restart behaviour and
start order. Source of truth for the compose bundles in `deploy/hackathon/`; `tests/test_run_health_contract.py` enforces the
parts that can be checked statically. Nothing here claims a running deployment: nothing is applied, and no image has been
pulled from ECR by these hosts yet. Services owned by other teams (agent-core serve, the platform) are rows that point to their
briefs; their numbers become facts when those teams deliver.

Variable NAMES only. Values come from Terraform-generated keys in the single Secrets Manager secret (`secrets.tf`,
`generated.tf`), from SSM parameters (`ssm.tf`), or from files rendered by `pulso-stack-prepare` (`prepare.sh.tftpl`).

## 1. Common facts

| Topic | Fact |
|---|---|
| Hosts | core `m7i-flex.large` (8 GiB, also runs Postgres), platform and engine `t3.small` (2 GiB), Amazon Linux 2023, **x86_64 only**: the AMI parameter and the compose plugin download are x86_64, every image is built `linux/amd64`. Arm types are accepted by a validation but would break `user_data`; do not use them. |
| Runtime | Docker + the compose plugin; `pulso-stack.service` (systemd, oneshot): `pulso-stack-prepare` then `docker compose -p pulso up -d --remove-orphans --force-recreate`. Restarts on failure every 30 s. |
| Images | `<KEY>_IMAGE` variables in `/srv/stack/.env`, rendered from SSM `/pulso/<workload>/images/<key>` as `repo@sha256:digest`. A new digest never changes the instance. |
| Secrets | rendered to `/run/pulso/env/<service>.env` (tmpfs, 0600) and `/run/pulso/files/<service>/` (0400, uid 10001). Never in `.env`, never in compose. |
| User | every app container runs as uid 10001 (`user:` in compose or `USER` in the image). Bind-mounted data dirs must therefore be owned by 10001: `pulso-stack-prepare` does that for `/srv/data/pulso`, `/srv/data/exporter`, `/srv/data/tools`, `/srv/data/agent`. |
| Logs | stdout and stderr, JSON where the service supports it, `json-file` 10 MB x 3 per container, shipped to CloudWatch Logs when the agent is enabled. |
| Restart | `restart: unless-stopped` for long-running services, `"no"` for one-shot migrations. **Docker does not restart an unhealthy container**: `pulso-autoheal.timer` does for pulso and agent-core (section 6.1) and `deploy-stack.sh` looks at health during a deploy (section 5). |
| Health rule of a deploy | every container healthy or exited 0, twice in a row, within 300 s; otherwise the previous digests are restored. |

## 2. Per service

### llm-gateway (core host, owned by us: image from the `llm-gateway` repo)

| | |
|---|---|
| Image | `Dockerfile` in the repo: `golang:1.27` build, `gcr.io/distroless/static-debian12:nonroot` runtime, static binary, tag-pinned bases (digest pinning is a release-time step, see the runbook). 17 MB, amd64 (built with Podman in this lane). tool-service image: 250 MB. |
| Command | `ENTRYPOINT ["/llm-gateway"]`, no arguments. |
| Environment | `GATEWAY_CONSUMERS` and `LLM_ENDPOINTS` (SSM, derived), `GATEWAY_TOKEN_<CONSUMER>` for AGENT_CORE, AGENT_SERVE, ENGINE, SUPPORT_PLATFORM (Terraform-generated), `OPENROUTER_API_KEY` and the other provider keys (out of band), `JEV_API_KEY` (out of band); optional `LISTEN_ADDR`, `MAX_BODY_BYTES`, `OTEL_EXPORTER_OTLP_ENDPOINT`, `LLM_GATEWAY_TRACE_CONTENT`. Invalid config exits 2. |
| Port | 8080. Published to the host so the engine host can call `<core private IP>:8080`; the core security group allows it from the engine security group only. Compose-network peers use `llm-gateway:8080`. |
| Probe | `["CMD", "/llm-gateway", "-healthcheck"]` (the binary GETs its own `/healthz`), interval 15 s, timeout 5 s, retries 5, start period 10 s. **Liveness only**: there is no readiness endpoint; a bad provider key shows up as per-call errors. |
| Restart | `unless-stopped`. Crash-loop causes: unparsable `GATEWAY_CONSUMERS`/`LLM_ENDPOINTS`, a consumer whose `GATEWAY_TOKEN_*` variable is empty. |
| Order | no dependency. agent-core and core-runtime wait for it to be healthy. |
| Limits | 128 MB (Go, stateless). |

### tool-service (core host, owned by us: image from the `tool-service` repo)

| | |
|---|---|
| Image | `Dockerfile`: `python:3.12-slim` + `uv:latest` (unpinned) + `uv sync --frozen --no-dev`, entrypoint `CMD ["tool-service"]`. Runs as root unless the compose `user:` is set (it is: 10001). No `HEALTHCHECK` in the image; compose declares the probe. |
| Environment | `TOOL_SERVICE_TOKENS` (`consumer:token,...`, generated), `TOOL_DATA_DIR`, `TOOL_FILED_DB`, `HOST`, `PORT` (compose), optional `TOOL_POINTER_TTL_S`. Missing tokens or data dir exits with a named reason. |
| Port | 8080, internal only (agent-core reaches it over the compose network). |
| Volumes | `/srv/data/tools/data` (read-only: data-pipeline publication synced from S3 at every start), `/srv/data/tools/state` (SQLite of filed PQRs, snapshotted). |
| Probe | `GET /healthz` via `python -c`, 15 s / 5 s / 5 retries / 20 s start period. **Liveness**. `/readyz` (dataset and store reachable) exists and returns 503 until a publication is mounted; it is reported by agent-core's own `/readyz`, not used as the container health, so a missing publication does not roll back a deploy. |
| Restart / order | `unless-stopped`; no dependency; agent-core waits for it to be healthy. |
| Limits | 1024 MB (DuckDB; set `memory_limit` in the service if it reads large tables). |

### engine `pulso` (engine host, owned by us: image from the `improvement-engine` repo)

| | |
|---|---|
| Image | root `Dockerfile`: node 22 (console), `rust:1-bookworm` (build, `--locked`, `CARGO_BUILD_JOBS=1`), `debian:bookworm-slim` runtime, uid 10001, 98.1 MB measured earlier on Podman, `HEALTHCHECK` present (only kept by `--format docker` builds). Bases are tag-pinned, two of them floating. |
| Command | `ENTRYPOINT ["/usr/local/bin/pulso"]`, `CMD ["run"]`. |
| Environment (secrets) | `PULSO_DATABASE_URL`, `PULSO_ADMIN_TOKEN`, `PULSO_DEBUG_TOKEN` (the last two generated, at least 24 characters, different: without them the process exits 2), `PULSO_LLM_GATEWAY_KEY`, `PULSO_SERVICE_SEED_HEX`. |
| Environment (SSM) | `PULSO_DATA_MODE` (`dataset`), `PULSO_SERVICE_KID`, `PULSO_LLM_GATEWAY=enabled`, `PULSO_BASE_PATH=/pulso`, `PULSO_CORE_ADDR`, `PULSO_LLM_GATEWAY_ADDR` (IP literals: the client refuses DNS names for plaintext), `PIPELINE_ROOT`. From compose: `PULSO_STORAGE_BUCKET`, `PULSO_STORAGE_PREFIX`, `PULSO_CORE_URL`. Baked in the image: `PULSO_LISTEN_ADDR=0.0.0.0:8080`, `PULSO_ALLOW_NON_LOOPBACK=1`, `PULSO_CONSOLE_DIR`, `PULSO_WORK_DIR`, `PULSO_STORE_DIR`. |
| Port, volume | 8080 behind the Caddy proxy (CloudFront reaches only the proxy, which keeps the `/pulso` prefix and hides `/internal`); `/srv/data/pulso` -> `/var/lib/pulso`. |
| Probe | `["CMD", "pulso", "healthcheck"]` = GET `/pulso/readyz` on loopback; 15 s / 5 s / 5 retries / **60 s start period**. `/healthz` is process-up, `/readyz` is 200 only when migrations are applied, the database answers and every task is alive (503 reasons: `migrations_pending`, `migrations_failed`, `db_unreachable`, `task_starting`, `task_dead`, `shutting_down`). The proxy waits for it (`service_healthy`). |
| Restart | `unless-stopped`; exit codes 0 clean, 1 task died or startup failure, 2 refused configuration (a crash loop with a named reason in the log), 3 cut at the shutdown deadline. Compose does not restart a dead task that keeps the process alive and not ready. `stop_grace_period` 70 s over `PULSO_SHUTDOWN_GRACE_SECS` 25. |
| Order | Postgres is on the core host: no compose dependency across hosts. `pulso` binds first, retries the migrations every 2 s while the database is unreachable and reports `db_unreachable`. **First boot**: the DSN is the master role until `pulso-db-bootstrap` has enabled the `pulso_app` login (section 6.2), then the secret is switched to `pulso_app`. |
| Limits | 512 MB on a 2 GiB host. |
| Not in the image | `steps_cli`, the Python scorers and the demo-loop scripts. `pulso run` is the monitor and worker over platform or dataset sources; the value loop of the demos is driven from the engine repo (see `docs/prodlike-rehearsal.md`). |

### OTLP forwarder (owned by us: code in `improvement-engine/scripts/o11y`, recipe in `docker/otlp-forwarder.Dockerfile`)

| | |
|---|---|
| Image | `docker/otlp-forwarder.Dockerfile`, build context the engine repo; `python:3.12-slim-bookworm`, uid 10001, standard library only, `HEALTHCHECK` on `/healthz`. |
| Command | `python /opt/pulso/scripts/o11y/otlp_forwarder.py --port 4318`. |
| Environment | `LANGFUSE_BASE_URL`, `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` (`langfuse.env`, out of band), `PULSO_O11Y_ALLOW_EXTERNAL=1` (baked: the upstream is external). |
| Port | 4318 on **127.0.0.1 only** (no bind option). On a host it is therefore a sidecar in the network namespace of its producer (`network_mode: service:<producer>`), see `deploy/hackathon/core/compose.observability.yaml`. |
| Probe / restart | `/healthz` (counts only, no content), 15 s / 5 s / 5 / 10 s; `unless-stopped`. It queues in memory: a restart loses unsent spans. |
| State | **Defined, not wired into Terraform**: needs a decision (section 6). The engine has no OTel exporter; its story traces are posted by `scripts/o11y/engine_trace.py`. |
| Limits | 96 MB each. |

### agent-core serve and the platform

Placeholders until their teams deliver. Today the compose files already encode `agent-core` (`serve ... --registry-api`,
port 8001, `/readyz`, `agent-core-migrate` one-shot, `AGENT_IMAGE`) and the platform (`support-platform-api` :8000,
`support-platform-web`, proxy :80). The expectations are in `docs/reports-claude/ASKS/BRIEF_agent-core_serve_2026-10-05.md`
and `BRIEF_platform_prod_ready_2026-10-05.md` (outside this repository). The compose probes assume `/readyz` on 8001
(agent-core, exists) and `GET /` on 8000 (platform API: weaker than a readiness endpoint, brief item).

## 3. Core host start order

`docker.service` -> `pulso-stack.service` -> `pulso-stack-prepare` (S3 sync of the bundle, ECR login, image digests, env and
files, artifact and publication sync) -> compose: `postgres` (first start only: init scripts create databases and roles;
healthy by `pg_isready`, 10 s x 12, 30 s start) -> `core-migrate` (one-shot) -> `core-runtime` and `agent-core-migrate` ->
`agent-core`. `llm-gateway` and `tool-service` start at once; `core-runtime` and `agent-core` wait until the gateway is healthy
and `agent-core` also for the tool-service. An empty data volume with a `CHANGE_ME` password refuses the init (by design).

## 4. Resource budget against the instance size

| Host | Sum of `mem_limit` | Instance | Note |
|---|---|---|---|
| core | 4352 MB (postgres 1536, core-runtime 768, agent-core 768, tool-service 1024, exporter 128, gateway 128) + 512 MB of one-shot migrations | 8192 MB | 53 percent; a Terraform test caps the sum at 70 percent. Forwarders add 192. |
| platform | 640 MB | 2048 MB | |
| engine | 576 MB | 2048 MB | `t3` is burstable: CPU credits, watch the `unlimited` surcharge. |

## 5. Deploy, rollback

`aws-prod.ps1 deploy -Service <name> -Digest sha256:... -Wait` writes the SSM parameter and runs `deploy-stack.sh` through SSM:
render, pull (running containers untouched), `up -d`, wait healthy twice, otherwise restore the previous digests and report
`DEPLOY_RESULT=rolled_back`. `-Rollback` re-deploys the previous digest from the parameter history. Details:
[the build and release runbook](runbooks/build-and-release.md).

## 6. Decisions taken and what remains

1. **Auto-restart (done).** `pulso-autoheal.timer` (every 60 s, from 5 min after boot, `user_data`) restarts containers of the `pulso`
   project whose health is `unhealthy`, for `AUTOHEAL_SERVICES` (default `pulso agent-core`), at most `AUTOHEAL_MAX_PER_HOUR` (6) per
   service, so a crash loop is left to the deploy rollback. For other services (`tool-service`, `llm-gateway`, `support-platform-api`)
   add them to `AUTOHEAL_SERVICES` in the service Environment; they all have probes. Never restarts one-shot jobs.
2. **Engine database bootstrap (done, one manual switch).** `pulso-db-bootstrap` (core compose, one-shot, Postgres master, quiet,
   idempotent) enables the `pulso_*` logins with `30_pulso_logins.sql` once the engine's migrations created the roles, and exits 0
   with a message otherwise. Order: first start with `PULSO__PULSO_DATABASE_URL` as the master role, so the engine migrates; a core
   deploy (or boot) runs the job; when it logs `logins enabled`, switch the secret to `pulso_app` and redeploy the engine.
   `PULSO_DATA_MODE` is now `dataset` (SSM, derived).
3. **Improvement loop on the engine host (job defined, unwired).** The engine image carries `pulso loop` (engine PRs 112, 119, 122): one
   run of cells to sensor, Scout, Verifier, Builder, regression proof, registry writer and announce. It mints its own Ed25519 `builder`
   credential from `PULSO_SERVICE_SEED_HEX` + `PULSO_SERVICE_KID` (the public key must be listed under that kid in the Core's staff-keys).
   The job is `deploy/hackathon/engine/compose.loop.yaml` (command `loop`, env of `docs/dev/ENGINE_PROD.md` in the engine repo), opt-in
   and not wired to Terraform. Still infra's: sync `engine/inputs/` to `/srv/data/pulso/inputs` and a timer.
4. **OTLP forwarder wiring:** deferred until the base cycle works (recipe and fragment exist).
5. **Host replacement on apply:** accepted (`user_data` changes).
6. **Supply chain, to do at deploy time (nothing downloaded here):**
   * compose plugin: from a trusted machine fetch the release asset `docker-compose-linux-x86_64` and its `.sha256` for the pinned
     `compose_version` (`v2.29.7`), compare, then put the checksum in `user_data` (`echo "<sha256>  file" | sha256sum -c`) before
     `chmod`; commit the change with the version.
   * postgres: `podman pull postgres:16.4`, tag `<registry>/prod/postgres:16.4`, push, read the registry digest, store
     `<registry>/prod/postgres@sha256:<digest>` in SSM `/pulso/core/images/postgres` (the start script renders `POSTGRES_IMAGE`; the
     compose files already prefer it over the Docker Hub tag).
