# Secrets wiring: who sources every variable (names only)

Decision of 2026-10-05: the ONLY things a human supplies are API keys of external providers (OpenRouter, JEV, optionally Langfuse; see [human-secrets-only](human-secrets-only.md)). Every other secret, token, key, DSN, password and data-governance file is wired by this repository: generated once by Terraform, derived from other values, or authored as a config file with a least-privilege default. No value appears in Git, chat, a test fixture or a rendered bundle file; this page lists names only. Nothing here was applied.

Mechanics. One Secrets Manager secret `<prefix>/hackathon` (JSON). Terraform (`terraform/modules/hackathon_data/generated.tf`, `wiring.tf`) writes every generated and derived value into it at creation; the secret version ignores later changes, so an apply never rotates a value and never overwrites one set by hand. The sensitive output `generated_secrets` carries the same values for `aws-prod.ps1 seed-secret-keys` (merge only, for a secret that already existed). The host start script renders `<SERVICE>__<VAR>` keys into `/run/pulso/env/<service>.env` and `FILES__<SERVICE>__<NAME>` keys into `/run/pulso/files/<service>/<NAME>`.

Legend. **G** generated (random_password, random_bytes, tls Ed25519). **D** derived (assembled from generated values and host names). **F** authored config file in `deploy/hackathon/config/` (read by Terraform `file()` into the secret). **H** human (external provider key). **L** literal or SSM value (not secret). **C** code default of the service, nothing to provide. The `CHANGE_ME` placeholder survives only on the **H** rows.

## Hosts and addresses used by D

Containers on the core host reach Postgres as `postgres:5432`; the platform and engine hosts as `core.<private zone>:5432` (A record from the compute module; no cycle, the zone name comes from the network module). RDS mode uses the instance address everywhere with `sslmode=require`. Role passwords are alphanumeric (`special = false`), so DSNs need no URL encoding. The engine client wants IP literals for plain HTTP (`PULSO_CORE_ADDR`, `PULSO_REGISTRY_ADDR`, `PULSO_PLATFORM_URL`, `PULSO_LLM_GATEWAY_ADDR`): those stay SSM values derived from the private IPs in the environment root (not secret).

## agent-core serve (core host)

| Variable | Source | Note |
|---|---|---|
| `AGENTCORE_REGISTRY_DSN` | D (`AGENT__AGENTCORE_REGISTRY_DSN`) | `agent_app` on `agent_runtime`, password G |
| `AGENTCORE_EVAL_DSN` | D | `agent_app` on `agent_eval` |
| `AGENTCORE_MIGRATE_DSN`, `AGENTCORE_MIGRATE_EVAL_DSN` | D | `agent_owner`, used only by the migrate one-shot |
| `AGENTCORE_KEYS_FINGERPRINT`, `AGENTCORE_KEYS_TOKEN_MAP` | G | `k1:` + 32 random bytes |
| `AGENTCORE_JEV_API_KEY` | H | the same key as the gateway's JEV key: `set-secret GATEWAY__JEV_API_KEY` writes both |
| `AGENTCORE_LLM_GATEWAY_TOKEN` | G | equals the gateway's `GATEWAY_TOKEN_AGENT_SERVE` |
| `AGENTCORE_TOOL_SERVICE_TOKEN` | G | equals the `agent-core` token in tool-service `TOOL_SERVICE_TOKENS` |
| `AGENTCORE_GRANTS_TOKEN` | G | equals the platform `CC_INTERNAL_SERVICE_TOKEN` |
| `AGENTCORE_IDENTITY_KEYS_FILE` | G (file) | public keys of platform principal, delegation and engine |
| `AGENTCORE_STAFF_KEYS_FILE` | G (file) | platform staff key plus engine key (ADR 0009 trust note) |
| `AGENTCORE_AUTHZ_FIELD_GRANTS_FILE` | F (`config/agent/field-grants.json`) | see "Reviewable defaults" |
| `AGENTCORE_FIELD_CLASSIFICATION_FILES` (overlay half) | F (`config/agent/field-overlay.json`) | agent-core's `scripts/e2e/field-overlay.json`; the catalog half is the data-pipeline publication synced to the host |
| `AGENTCORE_LANG_THRESHOLDS` | F (`config/agent/lang-thresholds.json`) | agent-core `scripts/e2e/lang-thresholds.json`, keyed by calibration id (`lang-cal-demo`); data team: add the deployed calibration ids so Portuguese is answered in Portuguese |
| `AGENTCORE_FX_RATES_FILE` | F (`config/agent/fx-rates.json`) | fixed invented rates from agent-core `serve_state.py` |
| `AGENTCORE_TOOL_SERVICE_URL`, `_GRANTS_URL`, `_LLM_GATEWAY_URL`, `_SERVE_AGENTS`, `_REGISTRY_API`, `_KEYS_RELOAD_SECONDS`, `_AUTHZ_BIND_KEYS`, `_CALIBRATION_DIR`, `_CLASSIFIER_ARTIFACTS_DIR`, timeouts, readiness switches, caps, `_AUTO_MIGRATE`, `_SHUTDOWN_GRACE_SECONDS` | L | `compose.agents.yaml` |
| `AGENTCORE_DB_POOL_MAX`, `_MAX_INFLIGHT`, `_WORKER_THREADS` | L | by instance memory (`agent_limits`) |
| `AGENTCORE_BLOB_*`, `_EVENTS_TOPIC_ARN`, rate limits, `_DAILY_BUDGET_USD`, `_GIT_SHA` | C | unset on purpose |
| `AGENTCORE_ALLOW_DOUBLES` / `_ALLOW_DEMO` | never | prohibited; the start script and tests refuse it |
| Calibration and classifier artifacts | data team (S3 `core/artifacts/`) | not a secret and not a variable; synced at start |
| `OTEL_*`, `AGENTCORE_TRACE_*` | L | only with the forwarder; the Langfuse keys stay in the sidecar |

Secret files (`FILES__AGENT__<NAME>`, rendered under `/run/pulso/files/agent`): IDENTITY_KEYS and STAFF_KEYS (G), FIELD_GRANTS, FIELD_OVERLAY, FX_RATES, LANG_THRESHOLDS (F).

## llm-gateway (core host)

| Variable | Source | Note |
|---|---|---|
| `GATEWAY_CONSUMERS`, `LLM_ENDPOINTS` | L (SSM, derived) | single endpoint `openrouter` |
| `GATEWAY_TOKEN_<CONSUMER>`: `GATEWAY_TOKEN_AGENT_CORE`, `GATEWAY_TOKEN_AGENT_SERVE`, `GATEWAY_TOKEN_ENGINE`, `GATEWAY_TOKEN_SUPPORT_PLATFORM` | G | one per consumer, distinct |
| `OPENROUTER_API_KEY` | H | `GATEWAY__OPENROUTER_API_KEY` |
| `JEV_API_KEY` | H | `GATEWAY__JEV_API_KEY` (fans out to agent-core) |
| `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY` | removed | the gateway has no such endpoint; the key names were never read |
| `JEV_BASE_URL`, `JEV_MAX_RETRIES`, `JEV_BACKOFF_MS`, `LISTEN_ADDR`, `MAX_BODY_BYTES`, `LLM_GATEWAY_TRACE_*` | C | |

## tool-service (core host)

| Variable | Source | Note |
|---|---|---|
| `TOOL_SERVICE_TOKENS` | G | `agent-core:<token>` |
| `TOOL_DATA_DIR`, `TOOL_FILED_DB`, `HOST`, `PORT` | L | `compose.agents.yaml`; publication synced from S3 at start |
| `TOOL_POINTER_TTL_S` | C | |

## support-platform (platform host)

| Variable | Source | Note |
|---|---|---|
| `CC_SESSION_SECRET` | G | 64 alphanumerics (minimum 32 bytes) |
| `CC_TOTP_SECRET_KEY` | G | Fernet key (urlsafe base64 of 32 bytes). Rotating it makes every sealed TOTP secret unreadable (users re-enrol) |
| `CC_DATABASE_URL` | D | `postgresql+asyncpg://platform_app...@core.<zone>:5432/platform`; needs `platform_database_enabled` |
| `CC_MIGRATE_DATABASE_URL` | D (assumed name) | `platform_owner`; the platform has no migrate step today (blocker 1 of [deploy-readiness](deploy-readiness.md)) |
| `CC_INTERNAL_SERVICE_TOKEN` | G | one value with `AGENTCORE_GRANTS_TOKEN` and `PULSO_PLATFORM_SERVICE_TOKEN` |
| `CC_AGENT_KEYS_FILE` (secret file `AGENT_PRIVATE_KEYS`) | G (file) | private.json: principal, delegation, staff seeds |
| `CC_BANK_CUSTOMER_LINKS_FILE` | F (`config/support/bank-customer-links.json`) | `{}`, see "Reviewable defaults" |
| `CC_PUBLIC_APP_URL`, `CC_CORS_ORIGINS` | L (SSM, derived from the CloudFront domain) | CORS is a JSON list |
| `CC_AGENT_CORE_URL` | L | compose |
| `CC_ENV`, `CC_SEED_DEMO_DATA`, `CC_DEV_MAILBOX`, `CC_DEV_MFA_CODE`, `CC_ASSISTANT_STEP_UP_CODE`, TTLs, lockout, stage thresholds, agent ids | C | NOT set: the platform runs in its `dev` mode with demo data and weak dev codes. Whether the demo needs `CC_ENV=prod` (which forbids demo seed and has no mail sender) is a platform-team decision |
| `VITE_API_URL` | build time | image build, not a runtime secret |

## Engine (engine host): `pulso run`, `pulso loop`, loader, forwarder

| Variable | Source | Note |
|---|---|---|
| `PULSO_DATABASE_URL` | D | `postgresql://pulso_master:...@core.<zone>:5432/pulso`. The master is used because the engine creates its roles at its first start. Hardening to `pulso_app` after `pulso-db-bootstrap` printed `logins enabled` is a later, optional step ([run-and-health](run-and-health.md)); it is not needed for the demo and is accepted risk |
| `PULSO_ADMIN_TOKEN`, `PULSO_DEBUG_TOKEN` | G | distinct, 48 characters (minimum 16) |
| `PULSO_SERVICE_SEED_HEX` | G | Ed25519 seed, 64 hex; the public half is in agent-core staff-keys under `PULSO_SERVICE_KID` |
| `PULSO_SERVICE_KID` | L (SSM, derived) | `pulso-engine-<suffix>` |
| `PULSO_LLM_GATEWAY_KEY` | G | equals `GATEWAY_TOKEN_ENGINE` |
| `PULSO_PLATFORM_SERVICE_TOKEN` | G | equals the platform internal token |
| `PULSO_PG_PRODUCT_DSN` | D | `platform_exporter_ro` on `platform`; needs `platform_database_enabled` |
| `PULSO_CORE_ADDR`, `PULSO_REGISTRY_ADDR`, `PULSO_LLM_GATEWAY_ADDR`, `PULSO_PLATFORM_URL` | L (SSM, private IPs) | |
| `PULSO_DATA_MODE`, `PIPELINE_ROOT`, `PULSO_BASE_PATH`, `PULSO_SOURCE_*`, loop knobs | L | |
| `PULSO_REGISTRY_TOKEN` | never | the engine mints short-lived credentials; no static token exists |
| `PULSO_GATEWAY_KEY`, `PULSO_PG_DATASET_DSN`, `PULSO_PG_WATERMARK_DSN`, `PULSO_PG_LOADER_DSN` | not used here | the dataset adapter reads files; the Parquet-to-Postgres loader is not deployed |
| `PSEUDONYM_KEY` (`LOADER__PSEUDONYM_KEY`) | G | 32 random bytes as 64 hex. Read by the data-pipeline loader (`auto_loader_enabled`). **Rotating it changes every pseudonym** (a planned re-publication, and any customer link built on old pseudonyms breaks). The engine itself reads no pseudonym key (survey of improvement-engine found none) |
| Loader role credentials | none | the loader script assumes a role at run time; nothing stored |
| `LANGFUSE_PUBLIC_KEY`, `LANGFUSE_SECRET_KEY` | H (optional) | only with `otlp_forwarder_enabled` |
| `LANGFUSE_BASE_URL` | L | |

## Postgres (core host container)

| Variable | Source | Note |
|---|---|---|
| `POSTGRES_PASSWORD` (`DB__POSTGRES_PASSWORD`) | G | the master (user `pulso_master`) |
| `DB_PASSWORD_CORE_OWNER`, `_CORE_APP`, `_CORE_EVAL_APP`, `_CORE_EXPORTER_RO`, `_PULSO_APP`, `_PULSO_LOADER`, `_PULSO_RAW_RO`, `_PULSO_AUGMENTED_RO`, `_PULSO_PRODUCT_RO`, `_AGENT_OWNER`, `_AGENT_APP`, `_PLATFORM_OWNER`, `_PLATFORM_APP`, `_PLATFORM_EXPORTER_RO`, `_TOOLS_OWNER`, `_TOOLS_APP` | G | applied by `initdb` on an empty volume; a volume initialised earlier keeps its old passwords (run the SQL again to rotate) |
| `CORE__PULSO_BRIDGE_CONTROL_SIGNER`, `_LAB_SIGNER` | G | legacy core-bridge only; random, format never confirmed |
| `COMMON__ORIGIN_VERIFY` | G | CloudFront to Caddy header |

## Reviewable defaults (authored files)

All four are non-secret configuration that rides in the secret only because the start script already renders files from it. Flagged for review by the owners before any real data is served.

- `config/agent/field-grants.json`: `[["valor","customer_answer"],["valor","advisor_view"],["valor","agent_guidance"]]`. Least privilege that lets the financial field of the overlay be read for the three purposes; public fields need no grant, everything else (the data catalog's non-public fields) stays unreadable. For the agent-core and data teams: add the catalog fields the tools must expose, by name and purpose.
- `config/agent/field-overlay.json`: copied from agent-core `scripts/e2e/field-overlay.json` (classification of the engine's own fields). Anything not classified is treated as `pii_direct`.
- `config/agent/lang-thresholds.json`: agent-core's e2e thresholds (calibration id `lang-cal-demo`); useful only if the deployed calibration carries that id.
- `config/agent/fx-rates.json`: invented fixed USD rates from agent-core `serve_state.py`, for rehearsing `convertir_moneda`. Finance owns real rates.
- `config/support/bank-customer-links.json`: `{}`. The file maps platform customer ids to dataset customer ids; the real ids are not in any repository, so the demo starts with no links. The data team provides the mapping (it depends on the pseudonym key above).

## Rotation and lifecycle

Generated values are created once. To rotate one: change it in the secret by a reviewed procedure (engine key: [agent-core-serve](agent-core-serve.md#7-rotation-of-the-engine-key-a5)), never with `terraform apply -replace` on the secret version. A secret that existed before this wiring is completed with `aws-prod.ps1 seed-secret-keys`: it adds only missing or `CHANGE_ME` keys and skips a derived DSN whose password was kept (it names the skipped keys), so a DSN never disagrees with its password.

## Not verified

No apply, no plan, no running service. Unconfirmed: that the asyncpg DSN (`?ssl=require` on RDS only) is accepted by support-platform, that the platform runs against Postgres at all (no migrations yet), the format of the legacy bridge signers, that the pseudonym key format (64 hex) is what data-pipeline expects, and that the demo works with the minimal field grants.
