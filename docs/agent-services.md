# Agent services: agent-core serve and tool-service on the core host

Turns on the agents of support-platform (assistant, copilot, builder): `agentcore serve` from the agent-core repository
and the `tool-service` it calls, on the core host, wired to the platform host. Everything sits behind
`agent_services_enabled` (default `false`); with it off, nothing in this page exists.

Nothing here is applied or verified against AWS: Terraform is checked with mocked providers, the bundles with static
tests (`tests/test_agent_services_contract.py`). The open items at the end are not solved by this change.

## What runs where

```
platform host                                core host (m7i-flex.large, free_plan)
 support-platform-api :8000  ---- 8001 ----> agent-core (serve, :8001)  --> llm-gateway :8080 (compose network)
   (published to sg_core only) <--- 8000 ---   |  grant_active             --> tool-service :8080 (compose network)
 proxy :80 <- CloudFront                       |                            --> JEV (443, outbound)
   (/api/v1/internal/* refused)                agent-core-migrate (one-shot, owner DSN)
                                               core-runtime :8000, core-exporter, core-migrate (unchanged)
                                               postgres :5432 (databases agent_runtime, agent_eval added)
```

| Piece | Where it comes from |
|---|---|
| `deploy/hackathon/core/compose.agents.yaml` | merged after `compose.yaml` and `compose.postgres.yaml` (COMPOSE_FILE in `.env`) |
| `deploy/hackathon/platform/compose.agents.yaml` | publishes the API on 8000 and points it to agent-core |
| `agent.env`, `tools.env` | secret keys `AGENT__*`, `TOOLS__*` |
| `/run/pulso/files/<svc>/<NAME>` | secret keys `FILES__<SVC>__<NAME>` written as files (tmpfs, 0400, uid 10001) by the start script |
| `/srv/data/tools/data/publish/` | data-pipeline's current publication, synced at every start from `lake/publish/` |
| network | `module.network`: platform -> core:8001, core -> platform:8000 (sibling security groups only) |
| IAM | `module.iam`: the core role reads `lake/publish/*` and `core/artifacts/*` (`var.core_read_prefixes`) |
| bucket policy | `module.data`: `gold_restricted` (published `.duckdb` and `lake/gold_restricted/`) is PII: only loader, break-glass and the core role (`var.restricted_reader_role_arns`) read it |

`core-runtime` (the engine's composed image, improvement-engine `core-bridge`) is untouched: support-platform needs
`serve` (runs, sessions, registry API, HTTP tools), which the pinned `core-runtime` does not have.

## Turn it on

1. Bootstrap: the two repositories `agent-core-serve` and `tool-service` are in the default `ecr_repositories`; run
   `.\scripts\aws-prod.ps1 bootstrap-plan` and `bootstrap-apply` once (adds the two repositories).
2. In `prod.tfvars`: `agent_services_enabled = true` and the two digests in `images.core`:
   ```hcl
   images = {
     core = {
       core    = "<registry>/pulso-prod/core-runtime@sha256:..."
       gateway = "<registry>/pulso-prod/llm-gateway@sha256:..."
       agent   = "<registry>/pulso-prod/agent-core-serve@sha256:..."
       tools   = "<registry>/pulso-prod/tool-service@sha256:..."
     }
     # platform, engine unchanged
   }
   ```
   Plan fails without both (`var.images` validation).
3. Build the images (the CodeBuild projects exist once the variable is on):
   ```powershell
   .\scripts\aws-prod.ps1 images -Profile pulso-prod -Service agent-core-serve -SourceDir D:\src\agent-core
   .\scripts\aws-prod.ps1 images -Profile pulso-prod -Service tool-service -SourceDir D:\src\tool-service
   ```
4. `agent_serve_args`: the piece flags of `serve`. The default names the seven real pieces of agent-core main
   (tools, authz, field classifier, grant_active, transcript in Postgres, calibration and classifier from artifact
   directories). Override it only to append flags (`--agents`, `--lang-thresholds`). Demo doubles (`testing.*`) are
   rejected by the variable and by `serve` itself.
5. Set the secret values (below), then `plan` and `apply`. A secret that already exists keeps its keys
   (`ignore_changes`): add the new keys with `set-secret`, or the Terraform-generated ones (tokens, key documents; ADR 0009) with `seed-secret-keys` (merge only).
6. Database: see below (new volume: automatic; existing volume: one command).
7. Restart order: core (`sudo systemctl restart pulso-stack`), then platform.

## Secret keys

All in the one secret `pulso-prod/hackathon`, set with `.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey <key>`.

| Key | Value |
|---|---|
| `AGENT__AGENTCORE_REGISTRY_DSN` | `postgresql://agent_app:<pw>@postgres:5432/agent_runtime` (container mode) |
| `AGENT__AGENTCORE_EVAL_DSN` | same role, database `agent_eval` |
| `AGENT__AGENTCORE_MIGRATE_DSN`, `AGENT__AGENTCORE_MIGRATE_EVAL_DSN` | same two databases as `agent_owner` (only `agent-core-migrate` uses them) |
| `AGENT__AGENTCORE_LLM_GATEWAY_TOKEN` | equal to `GATEWAY__GATEWAY_TOKEN_AGENT_SERVE` |
| `AGENT__AGENTCORE_JEV_API_KEY` | the JEV key (agent-core calls JEV directly today) |
| `AGENT__AGENTCORE_KEYS_FINGERPRINT`, `AGENT__AGENTCORE_KEYS_TOKEN_MAP` | `kid:base64` of 32 random bytes each |
| `AGENT__AGENTCORE_TOOL_SERVICE_TOKEN` | the token of consumer `agent-core` in `TOOLS__TOOL_SERVICE_TOKENS` |
| `AGENT__AGENTCORE_GRANTS_TOKEN` | equal to `SUPPORT__CC_INTERNAL_SERVICE_TOKEN` |
| `TOOLS__TOOL_SERVICE_TOKENS` | `agent-core:<token>` |
| `GATEWAY__GATEWAY_TOKEN_AGENT_SERVE` | a new gateway consumer; add `"agent-serve":{"token_env":"GATEWAY_TOKEN_AGENT_SERVE"}` to the SSM `GATEWAY_CONSUMERS` |
| `SUPPORT__CC_INTERNAL_SERVICE_TOKEN` | long random value |
| `DB__DB_PASSWORD_AGENT_OWNER`, `DB__DB_PASSWORD_AGENT_APP` | role passwords (container mode; unprefixed in rds mode) |
| `FILES__AGENT__IDENTITY_KEYS`, `FILES__AGENT__STAFF_KEYS` | the platform's PUBLIC key files (`gen_agent_keys`: `identity-keys.json`, `staff-keys.json`), one line of JSON |
| `FILES__AGENT__FIELD_GRANTS` | `[["field","purpose"], ...]`: what data governance lets agents read (empty list: nobody reads any field) |
| `FILES__AGENT__FIELD_OVERLAY` | agent-core's overlay of engine fields (`scripts/e2e/field-overlay.json`), one line of JSON |
| `FILES__AGENT__FX_RATES` | fixed rate table of `convertir_moneda`: `{"USD":"1","MXN":"0.055"}` (USD per unit; approximate, not a market source; without it the tool fails closed) |
| `FILES__SUPPORT__AGENT_PRIVATE_KEYS` | the platform's `private.json` (secret) |
| `FILES__SUPPORT__BANK_CUSTOMER_LINKS` | `{"CUS-...": "<dataset customer_id>"}` |

`GATEWAY_CONSUMERS` must list only consumers whose token is set: two consumers still on `CHANGE_ME` share a token and
the gateway refuses to start. More files for `serve` (for example `--lang-thresholds /run/files/LANG_THRESHOLDS`) are
any extra `FILES__AGENT__<NAME>` key plus the flag in `agent_serve_args`; no Terraform change.

## Database

Two databases owned by `agent_owner`, separate from core-runtime's (`terraform/modules/hackathon_data/sql/20_agent_databases.sql`).

- New Postgres volume (container mode): `initdb/10_init.sh` runs the file when `DB_PASSWORD_AGENT_OWNER` is in `db.env`.
- Volume initialised before (the usual case): once, on the core host after setting the two passwords and restarting:
  ```bash
  sudo docker compose -p pulso exec postgres psql -v ON_ERROR_STOP=1 -U pulso_master -d postgres -f /docker-entrypoint-initdb.d/sql/20_agent_databases.sql
  ```
- rds mode: run the same file as the master user from a host session (see [db-bootstrap](db-bootstrap.md)).

`agent-core-migrate` then creates the tables on every start (`agentcore migrate --app-role agent_app`).

## Data for tool-service

data-pipeline publishes to `s3://<bucket>/lake/publish/<run>/` and moves `lake/publish/latest.json` last
(`PIPELINE_ROOT=s3://<bucket>/lake`). At every start the core host copies the current run's `gold_restricted.duckdb`
and `field_classification.json` to `/srv/data/tools/data/publish/<run>/`, the catalog to `/srv/data/tools/current/`
(read by agent-core) and the pointer last. No publication: a warning, tool-service answers `data_unavailable`, the rest
starts. A new publication is picked up at the next `pulso-stack` restart or deploy. Filed PQRs live in
`/srv/data/tools/state/filed_pqrs.db` on the snapshotted data volume.

## Calibration and classifier artifacts

`serve` reads calibrations (`<run_id>.json`) from `AGENTCORE_CALIBRATION_DIR` and classifier artifacts (`<ref>.json`)
from `AGENTCORE_CLASSIFIER_ARTIFACTS_DIR`. They are data team output, uploaded once by an admin (the core role only
reads `core/artifacts/`):

```powershell
aws s3 sync D:\artifacts\calibrations s3://<bucket>/core/artifacts/calibrations/ --profile pulso-prod
aws s3 sync D:\artifacts\classifiers s3://<bucket>/core/artifacts/classifiers/ --profile pulso-prod
```

The start script mirrors both prefixes to `/srv/data/agent/artifacts/` (read-only mount `/artifacts`) at every start;
restart `pulso-stack` after an upload. Empty prefixes still give empty directories: `serve` starts, an absent
calibration means threshold 1.0 (nothing passes) and a decision model that names a missing classifier artifact fails
when used. The transcript needs nothing here: it lives in the agent database (`agentcore migrate` creates its table).

## Loading the agents (registry seed)

A new agent database has no agents. Load the seed once, with a real admin credential (agent-core verifies it with the
platform's staff public keys, `FILES__AGENT__STAFF_KEYS`):

1. Upload the seed directory (today agent-core's `tests/fixtures/registry-e2e`) from your machine:
   ```powershell
   aws s3 sync D:\src\agent-core\tests\fixtures\registry-e2e s3://<bucket>/core/artifacts/registry-seed/ --delete --profile pulso-prod
   ```
   then `sudo systemctl restart pulso-stack` on the core host (the start script mirrors it to
   `/srv/data/agent/artifacts/registry-seed/`).
2. On the platform host, sign a two-minute admin credential (support-platform `registry_admin_credential`):
   ```bash
   sudo docker compose -p pulso exec support-platform-api python -m cc_platform.scripts.registry_admin_credential --staff-id <staff id>
   ```
3. Within two minutes, on the core host (paste the credential at the hidden prompt):
   ```bash
   read -rs AGENTCORE_CREDENTIAL && export AGENTCORE_CREDENTIAL
   sudo -E docker compose -p pulso run --rm --no-deps -e AGENTCORE_CREDENTIAL agent-core \
     registry --verifier agent_core.composition.registry:staff_verifier import /artifacts/registry-seed
   unset AGENTCORE_CREDENTIAL
   ```
   `import` refuses an agent that already has releases (use a proposal then); it prints the imported releases.

The seed's decision models name calibration runs: put the matching `<run_id>.json` files in `core/artifacts/calibrations/`.

## Checks after a start

```bash
sudo docker compose -p pulso ps                     # agent-core healthy, tool-service healthy, agent-core-migrate exited 0
curl -s http://127.0.0.1:8001/readyz                # on the core host
curl -s -o /dev/null -w "%{http_code}" http://core.pulso.internal:8001/readyz   # from the platform host
```

## Open (not solved here)

- The real calibration and classifier artifacts (data team) do not exist yet; without them every decision stays below
  threshold.
- The engine's own tools (`seleccionar`, `convertir_moneda`, `obtener_handoff`, `leer_transcript`) are served by
  agent-core itself from the agent-core version that ships them; the copilot reads the assistant's conversation only
  when support-platform sends `assistant_session_id` (support-platform version with that change).
- tool-service image: runs as root and pins `uv:latest`; the bundle runs it as uid 10001, which needs the image's
  `/app` readable by that user.
