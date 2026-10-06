# agent-core serve on the core host: the environment contract, health, load caps, migrations, key rotation

The shared Core of ADR 0009 is agent-core's OWN image running `agentcore serve` (`docs/serve-env.md` and `deploy/compose/` in the agent-core repository are the source of truth; this page is how the infra repository meets that contract). It replaces the core-bridge wiring: with `agent_services_enabled` the services `core-migrate`, `core-runtime` and `core-exporter` (the improvement-engine `core-bridge` image) sit behind the compose profile `legacy-core-bridge` and are never created. Everything is OFF by default (`agent_services_enabled = false`), nothing is applied, and nothing here was exercised against AWS or against a running `serve` ([What is not verified](#what-is-not-verified)).

Checked by `tests/test_agent_core_serve_contract.py` (names, health, caps, ordering, never-doubles) and the Terraform tests of `terraform/envs/hackathon` and `terraform/modules/hackathon_compute`.

## 1. What runs

| Piece | Source | Notes |
|---|---|---|
| `agent-core-migrate` | `deploy/hackathon/core/compose.agents.yaml` | one-shot, `agentcore migrate --app-role agent_app`, owner DSNs, every deploy |
| `agent-core` | same | `agentcore serve --host 0.0.0.0 --port 8001`, app-role DSNs, 768 MB |
| `agent-core-sweep` | same, profile `sweep` | `agentcore sweep --once` from `pulso-agent-sweep.timer` every 5 minutes (closes expired runs as `abandoned`) |
| `tool-service`, `llm-gateway`, `postgres` | unchanged | `serve` waits for both to be healthy |
| `compose.agents.postgres.yaml` | container mode only | `agent-core-migrate` waits for a healthy Postgres |

Port: the image default is 8000 (its own `HEALTHCHECK` probes it). This host serves **8001** because that address is baked into the platform (`CC_AGENT_CORE_URL`), the engine (`PULSO_CORE_ADDR`, `PULSO_REGISTRY_ADDR`), the security groups and SSM; the compose probe overrides the image's. Changing it is a one-line move later, now that core-runtime no longer holds 8000.

## 2. Image, ECR repository and digest variables

- Image: agent-core's `Dockerfile` (multi-stage, uid 10001, bases pinned by digest, `ENTRYPOINT agentcore`). The infra repository neither builds nor owns it.
- ECR repository `pulso-prod/agent-core-serve` (bootstrap default). Pinned by digest only: `images.core.agent` in `prod.tfvars` (printed by `scripts/aws-prod.ps1 images`), seeded to SSM `/pulso/core/images/agent`, rendered as `AGENT_IMAGE` in `.env`. `images.core.core` (the old core-bridge image) is no longer needed: when it is absent, `CORE_IMAGE` aliases the agent image only so compose can interpolate the disabled legacy services.
- Build and push: [service-deployment](service-deployment.md) and the [build runbook](runbooks/build-and-release.md). `docker build --build-arg GIT_SHA=<sha>` makes `GET /version` report the commit (`AGENTCORE_GIT_SHA`, baked in the image).

## 3. Environment contract (every name of `serve-env.md`)

Legend. **literal**: a non-secret value in `compose.agents.yaml` (or its `.env` knob). **secret**: key `AGENT__<NAME>` of the one Secrets Manager secret, rendered into `agent.env` (tmpfs, 0600); Terraform generates it (G) or the human provides it (H). **file**: secret key `FILES__AGENT__<NAME>` written as a file under `/run/pulso/files/agent` (0400, uid 10001). **SSM**: optional non-secret parameter `/pulso/core/agent/<NAME>` rendered into `agent.env` without any Terraform change. **unset**: deliberately not set. Names only; no value appears in this repository.

### 3.1 Core

| Variable | Class | How it is set |
|---|---|---|
| `AGENTCORE_REGISTRY_DSN` | R, secret | secret (H), the `agent_app` DSN |
| `AGENTCORE_KEYS_FINGERPRINT` | R, secret | secret (G, `k1:` + 32 random bytes) |
| `AGENTCORE_KEYS_TOKEN_MAP` | R, secret | secret (G) |
| `AGENTCORE_JEV_API_KEY` | R, secret | secret (H): JEV; production `serve` does not start without it |
| `AGENTCORE_SERVE_AGENTS` | O | literal from `agent_serve_agents` (`AGENT_SERVE_AGENTS`), default `recepcion,disputas,consultas,copiloto-asesor` |
| `AGENTCORE_GIT_SHA` | O | baked in the image (build arg) |
| `AGENTCORE_DB_POOL_MAX` | O | literal from the instance-size table (section 4) |
| `AGENTCORE_PROPOSAL_QUOTA_PER_DAY` | O | config value from `agent_proposal_quota_per_day` (`AGENT_PROPOSAL_QUOTA_PER_DAY`), default `30` (agent-core's own default is 10, tripled); not a secret |
| `AGENTCORE_PROPOSAL_QUOTA_OVERRIDES` | O | config value from `agent_proposal_quota_overrides` (`AGENT_PROPOSAL_QUOTA_OVERRIDES`), default `pulso-engine=600` (`principal=limit,...`): the engine creates 2-3 proposals per finding and counts only its own; not a secret |
| `AGENTCORE_LANG_THRESHOLDS` | O | literal `/run/files/LANG_THRESHOLDS`, secret file `FILES__AGENT__LANG_THRESHOLDS` (authored, `deploy/hackathon/config/agent/lang-thresholds.json`; without it the language never switches) |
| `AGENTCORE_FX_RATES_FILE` | C | literal `/run/files/FX_RATES`, secret file `FILES__AGENT__FX_RATES` (H) |
| `AGENTCORE_IDENTITY_KEYS_FILE` | R | literal `/run/files/IDENTITY_KEYS`, secret file (G) |
| `AGENTCORE_REGISTRY_API` | O | literal `1` (the engine and the platform use `/v1/registry`) |
| `AGENTCORE_STAFF_KEYS_FILE` | C | literal `/run/files/STAFF_KEYS`, secret file (G): the platform's staff key and the engine's builder key |
| `AGENTCORE_EVAL_DSN` | C, secret | secret (H), separate database `agent_eval` |
| `AGENTCORE_KEYS_RELOAD_SECONDS` | O | literal `5` (the documented default, stated so rotation depends on it) |

`AGENTCORE_MIGRATE_DSN` and `AGENTCORE_MIGRATE_EVAL_DSN` (owner roles) are secrets read ONLY by the one-shot; `serve` and the sweep get them blanked in `environment` so the owner credentials never reach the long-running process.

### 3.2 The seven real pieces (no flags needed: they are `serve`'s defaults)

| Variable | Class | How it is set |
|---|---|---|
| `AGENTCORE_TOOL_SERVICE_URL` | C | literal `http://tool-service:8080` |
| `AGENTCORE_TOOL_SERVICE_TOKEN` | C, secret | secret (G, same value as `TOOLS__TOOL_SERVICE_TOKENS`) |
| `AGENTCORE_TOOL_SERVICE_TIMEOUT_S` | O | literal `10` (default) |
| `AGENTCORE_AUTHZ_FIELD_GRANTS_FILE` | O | literal `/run/files/FIELD_GRANTS`, secret file (H): without grants nobody reads any field |
| `AGENTCORE_AUTHZ_BIND_KEYS` | O | literal `subject_ref,customer_id` |
| `AGENTCORE_CALIBRATION_DIR` | C | literal `/artifacts/calibrations` (synced from `core/artifacts/calibrations/`) |
| `AGENTCORE_CLASSIFIER_ARTIFACTS_DIR` | C | literal `/artifacts/classifiers` |
| `AGENTCORE_FIELD_CLASSIFICATION_FILES` | C | literal `/catalog/field_classification.json,/run/files/FIELD_OVERLAY` (the publication's catalog, then the overlay secret file (H)) |
| `AGENTCORE_GRANTS_URL` | C | literal `http://platform.<private zone>:8000` |
| `AGENTCORE_GRANTS_TOKEN` | C, secret | secret (G, same value as the platform's `CC_INTERNAL_SERVICE_TOKEN`) |
| `AGENTCORE_GRANTS_TIMEOUT_S`, `AGENTCORE_GRANTS_CACHE_TTL_S` | O | literals `3` and `5` (defaults) |

### 3.3 External dependencies

| Variable | Class | How it is set |
|---|---|---|
| `AGENTCORE_LLM_GATEWAY_URL` | O | literal `http://llm-gateway:8080` |
| `AGENTCORE_LLM_GATEWAY_TOKEN` | O, secret | secret (G), the `AGENT_SERVE` consumer token of the gateway |
| `AGENTCORE_BLOB_BUCKET`, `AGENTCORE_BLOB_PREFIX`, `AGENTCORE_BLOB_KMS_KEY_ARN` | O | unset: with the bucket, `migrate` drops the FK to `reg_blobs`, so `agentcore blobs-backfill` must run first (a platform-team decision, [deploy-readiness](deploy-readiness.md#blockers-owned-by-the-support-platform-team)). To enable later, add the three as SSM parameters under `/pulso/core/agent/`; the instance role already reads `core/blobs/` |
| `AGENTCORE_EVENTS_TOPIC_ARN` | C | unset: only `agentcore relay` (outbox to SNS) reads it, a separate process nobody deploys yet |

### 3.4 Operation

| Variable | Class | How it is set |
|---|---|---|
| `AGENTCORE_ALLOW_DOUBLES` (alias `AGENTCORE_ALLOW_DEMO`) | prohibited | **ABSENT, always.** Section 8 |
| `AGENTCORE_AUTO_MIGRATE` | O | literal `0`: the app role has no DDL; the one-shot migrates (section 5) |
| `AGENTCORE_READY_REQUIRE_LLM_GATEWAY` | O | literal `1` (default stated) |
| `AGENTCORE_READY_REQUIRE_TOOL_SERVICE` | O | literal `1` (non-default: both run on this host and `serve` waits for them) |
| `AGENTCORE_MAX_INFLIGHT`, `AGENTCORE_WORKER_THREADS` | O | literals from the size table |
| `AGENTCORE_SHUTDOWN_GRACE_SECONDS` | O | literal `25`, below `stop_grace_period: 30s` |
| `AGENTCORE_RATE_MAX_HITS`, `AGENTCORE_RATE_WINDOW_SECONDS`, `AGENTCORE_RATE_SERVICE_MULTIPLIER`, `AGENTCORE_DAILY_BUDGET_USD` | O | unset (`serve`'s defaults, which the document calls "demo"): set per principal limits as SSM parameters under `/pulso/core/agent/` once the platform team states them |

### 3.5 Observability (only with `otlp_forwarder_enabled`, [otlp-forwarder](otlp-forwarder.md))

Set as literals in `compose.observability.yaml`: `OTEL_TRACES_EXPORTER` (`otlp`), `OTEL_EXPORTER_OTLP_ENDPOINT` (`http://127.0.0.1:4318`), `OTEL_EXPORTER_OTLP_PROTOCOL` (`http/protobuf`), `OTEL_SERVICE_NAME` (`agent-core`), `AGENTCORE_TRACE_LANGFUSE` (`1`) and `AGENTCORE_TRACE_CONTENT` (`0` unless `otlp_trace_content`). The Langfuse credentials are NOT here: `OTEL_EXPORTER_OTLP_HEADERS` and `OTEL_EXPORTER_OTLP_TRACES_HEADERS` stay unset because the sidecar holds the keys. Left at their defaults (never set): `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_TRACES_PROTOCOL`, `OTEL_RESOURCE_ATTRIBUTES`, `OTEL_TRACES_SAMPLER`, `OTEL_TRACES_SAMPLER_ARG`, `OTEL_SDK_DISABLED`.

## 4. Health, start period, load caps, shutdown

| | Value | Why |
|---|---|---|
| Liveness | `GET /healthz` | the process answers; what the image's own `HEALTHCHECK` uses |
| Readiness | `GET /readyz` | database, key files (`keys: fail` after a failed reload) and, because of the two switches, the llm-gateway and the tool-service |
| Container health | `/readyz`, 15 s interval, 5 s timeout, 5 retries, **60 s start period** | `deploy-stack.sh` and the consumers' `depends_on` gate on container health; the first start loads the artifacts and the schema check. Unhealthy after at most 60 + 5 x 15 s |
| Autoheal | `pulso-autoheal.timer` restarts an unhealthy `agent-core`, at most 6 per hour | a dependency outage that fails readiness therefore restarts serve a few times; restarts do not fix it, the cap bounds the noise |
| `stop_grace_period` | 30 s | above `AGENTCORE_SHUTDOWN_GRACE_SECONDS` 25 s, so uvicorn drains in-flight requests before docker kills |

Load caps follow the core instance (`local.agent_limits` in `terraform/envs/hackathon/main.tf`, rendered into `.env` as `AGENT_MAX_INFLIGHT`, `AGENT_WORKER_THREADS`, `AGENT_DB_POOL_MAX`). Beyond `AGENTCORE_MAX_INFLIGHT` `/v1` answers 503 with `Retry-After: 1`; probes never count.

| Core instance | Memory | max in-flight | worker threads | DB pool per process |
|---|---|---|---|---|
| `m7i-flex.large` (free_plan default) | 8 GiB | 32 | 16 | 10 |
| `c7i-flex.large`, `t3.medium` | 4 GiB | 16 | 12 | 6 |
| `t3.small` and smaller | 2 GiB | 8 | 8 | 4 |

The container is capped at 768 MB whatever the instance; the numbers are starting points chosen from the container limit and Postgres `max_connections=100` (shared with platform, tools and the engine; the one-shots add a short-lived connection each). They are NOT load-tested.

## 5. Migrations, ordering and `pulso-db-bootstrap`

Order on the core host (container mode): `postgres` healthy -> `agent-core-migrate` completed -> `agent-core` (also needs `tool-service` and `llm-gateway` healthy). `agentcore migrate` takes a transaction advisory lock and compares the schema digest stored in the database, so it is idempotent and safe if two instances race; it also re-applies the grants of `agent_app`. It runs on every deploy (`docker compose up`), so a new image never meets an old schema, and `serve` runs with `AGENTCORE_AUTO_MIGRATE=0` because its role cannot run DDL (set it to `1` only together with a DSN of the owner role).

`pulso-db-bootstrap` (enables the engine's `pulso_*` logins after the ENGINE's first start created the roles; see [db-bootstrap](db-bootstrap.md)) is independent of this chain on purpose: it waits up to `BOOTSTRAP_WAIT_SECS` and exits 0 whether or not the roles exist, and the agent databases do not depend on it. It only needs a healthy Postgres, like the migration.

In RDS mode there is no `postgres` service; the one-shot starts immediately and `serve`'s own `/readyz` reports an unreachable database.

## 6. Secrets, files, and the optional SSM knobs

Secrets by name only: `AGENT__AGENTCORE_REGISTRY_DSN`, `AGENT__AGENTCORE_EVAL_DSN`, `AGENT__AGENTCORE_MIGRATE_DSN`, `AGENT__AGENTCORE_MIGRATE_EVAL_DSN`, `AGENT__AGENTCORE_JEV_API_KEY` (all H) and the generated `AGENT__AGENTCORE_KEYS_FINGERPRINT`, `AGENT__AGENTCORE_KEYS_TOKEN_MAP`, `AGENT__AGENTCORE_TOOL_SERVICE_TOKEN`, `AGENT__AGENTCORE_GRANTS_TOKEN`, `AGENT__AGENTCORE_LLM_GATEWAY_TOKEN`; files `FILES__AGENT__IDENTITY_KEYS`, `STAFF_KEYS` (G), `FIELD_GRANTS`, `FIELD_OVERLAY`, `FX_RATES` (H). Who provides what: [deploy-readiness](deploy-readiness.md#secrets-checklist).

`pulso-stack-prepare` refuses to start the stack if any rendered env file contains `AGENTCORE_ALLOW_DOUBLES` or `AGENTCORE_ALLOW_DEMO` (a stray SSM parameter or secret key cannot switch the doubles on). It rewrites the key files IN PLACE (same inode), which is what lets `serve` see a rotated key without a restart.

## 7. Rotation of the engine key (A5)

Terraform generates the engine's Ed25519 pair as before: kid `pulso-engine-<agent_keys_suffix>` (default `pulso-engine-hk1`), the public key in the identity-keys and staff-keys documents, the seed as `PULSO__PULSO_SERVICE_SEED_HEX`, the kid as SSM `PULSO_SERVICE_KID`. The trust note of ADR 0009 stands: every key in staff-keys can claim any role; the engine never signs an approver role.

`serve` re-reads both key files every 5 seconds, keeps the last good keys when a reload fails (and `/readyz` says `keys: fail`), and needs no restart. Rotation is therefore add, mint with the new kid, then retire, driven by three Terraform variables (`engine_extra_key_suffixes`, `engine_active_key_suffix`, `engine_retire_base_key`). The secret version ignores later Terraform changes (so an apply never overwrites out-of-band values), hence each step ends with a merge of three keys into the secret, done by `scripts/engine_key_rotation.py` and `aws secretsmanager put-secret-value`. The user executes every step; nothing here runs by itself.

1. **Add.** `engine_extra_key_suffixes = ["hk2"]`; plan and apply (an offline plan shows one `tls_private_key.engine_extra["hk2"]`, the changed documents, no destroy). Merge: write the current secret and `terraform output -json generated_secrets` to two private files, run `python scripts/engine_key_rotation.py merge --secret <file> --generated <file> --out <file>` (it copies only `FILES__AGENT__IDENTITY_KEYS`, `FILES__AGENT__STAFF_KEYS` and, in step 2, `PULSO__PULSO_SERVICE_SEED_HEX`; prints key names and kids, never values), then `aws secretsmanager put-secret-value --secret-id <arn> --secret-string file://<out>`. Redeploy core (`aws-prod.ps1 deploy`); within 5 s `serve` publishes both kids. Check `GET /readyz` has no `keys: fail`.
2. **Mint with the new kid.** `engine_active_key_suffix = "hk2"`; apply (SSM `PULSO_SERVICE_KID` becomes `pulso-engine-hk2`); merge again with `--include-seed`; redeploy the engine host. The next `pulso loop` run (a new process) mints with the new kid; a running `pulso run` picks it up at its restart.
3. **Retire.** After a run succeeded with the new kid: `engine_retire_base_key = true`; apply; merge; redeploy core. The old kid disappears from both documents. Roll back at any step by reverting the variable and merging again; the previous key stays valid until step 3.

## 8. AGENTCORE_ALLOW_DOUBLES can never be set

`AGENTCORE_ALLOW_DOUBLES` (and its legacy alias `AGENTCORE_ALLOW_DEMO`) lets `serve` use `testing.*` doubles. It is forbidden in deployments and is enforced at four levels: no bundle file sets it; `agent_serve_args` rejects `testing.` and any allow-doubles switch; the secret and SSM key lists contain neither; `pulso-stack-prepare` aborts if either name reaches an env file. `tests/test_agent_core_serve_contract.py` scans the bundles, Terraform and templates for it.

## What is not verified

No image was built or run for this change, no `serve` was started, no Terraform ran against AWS. The facts about `serve` come from reading agent-core `main` (PRs 62 to 70: `docs/serve-env.md`, `deploy/compose/`, `Dockerfile`, `agent_core/composition/schema_version.py`). Unconfirmed: that `/readyz` of a real `serve` is green with these literals on this host, the load-cap numbers, the 60 s start period, that `AGENTCORE_AUTO_MIGRATE=0` is accepted together with an app role that already has the schema (the one-shot creates it first), and the key reload through the bind mount (the in-place rewrite is tested only as text).
