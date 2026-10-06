# Shared Postgres (one container on the core host)

Decision of 2026-10-05: ONE Postgres 16 container on the core host serves agent-core, support-platform and tool-service, plus the
engine's own schema. Separate databases and login roles per service; nothing is shared but the server process. Compute is the EC2
host with Docker Compose (no ECS). Nothing here is applied; Terraform is checked with mocked providers and static tests.

Switch: `platform_database_enabled = true` (needs `agent_services_enabled`, `database_mode = container`, i.e. the `free_plan`
profile). Off by default; with it off nothing on this page exists.

## Databases and roles

| Database | Owner (DDL, migrations only) | App role (DML) | Read-only role | Used by | SQL file |
|---|---|---|---|---|---|
| `core_runtime`, `core_eval` | `core_owner` | `core_app`, `core_eval_app` | `core_exporter_ro` | core-runtime (engine core-bridge) | `00`, `10` |
| `agent_runtime`, `agent_eval` | `agent_owner` | `agent_app` | none | agent-core `serve` | `20` |
| `platform` | `platform_owner` | `platform_app` | `platform_exporter_ro` (tables `event_log`, `cases` only) | support-platform; the engine's platform-exporter | `25`, `26` |
| `tools` | `tools_owner` | `tools_app` | none | tool-service state (SQLite today; roles ready) | `25` |
| `pulso` | `pulso_master` (engine migrations) | `pulso_app`, `pulso_loader` | `pulso_raw_ro`, `pulso_augmented_ro`, `pulso_product_ro` | the engine | engine `db/sql`, `30` |

Rules: `CONNECT` revoked from `PUBLIC` on every database; each role connects only to its own; owners are used only by the
migrate step; app roles get DML through default privileges of the owner; read-only roles also have
`default_transaction_read_only = on`. The exporter has NO default privileges: `26_platform_exporter_grants.sql` grants `SELECT`
on the two tables by name, so a new table with personal data is unreadable by the engine until a human adds it.

## Secrets

All in the one Secrets Manager secret (names only). Role passwords `DB__DB_PASSWORD_<ROLE>` (container mode) for `PLATFORM_OWNER`,
`PLATFORM_APP`, `PLATFORM_EXPORTER_RO`, `TOOLS_OWNER`, `TOOLS_APP`; DSNs (assembled by Terraform from the generated passwords, [secrets-wiring](secrets-wiring.md)):

| Key | Value shape | Rendered into |
|---|---|---|
| `SUPPORT__CC_DATABASE_URL` | `postgresql://platform_app:<pw>@core.<zone>:5432/platform` | platform host `support.env` |
| `MIGRATE__CC_DATABASE_URL` (assumed name; align with support-platform `deploy-env.md`) | same, role `platform_owner` | platform host (migration step only) |
| `PULSO__PULSO_PG_PRODUCT_DSN` | `postgresql://platform_exporter_ro:<pw>@core.<zone>:5432/platform` | engine host `pulso.env` |
| `PULSO__PULSO_PLATFORM_SERVICE_TOKEN` | generated, equal to `SUPPORT__CC_INTERNAL_SERVICE_TOKEN` | engine host `pulso.env` |

Non-secret (SSM, written by Terraform, engine host): `PULSO_PLATFORM_URL=http://<platform private IP>:8000`,
`PULSO_REGISTRY_ADDR=<core private IP>:8001`, `PULSO_ANNOUNCE_TO_PLATFORM=on`, `PULSO_SOURCE_ADAPTER=product-postgres`,
`PULSO_SOURCE_SCHEMA=public`. IP literals because the engine client refuses a DNS name for plain HTTP.

## Create the databases

- New volume: `initdb/10_init.sh` runs `25_platform_databases.sql` when `DB_PASSWORD_PLATFORM_OWNER` is in `db.env`.
- Existing volume (the usual case), once, after setting the five passwords and restarting `pulso-stack`:
  ```bash
  sudo docker compose -p pulso exec postgres psql -v ON_ERROR_STOP=1 -U pulso_master -d postgres -f /docker-entrypoint-initdb.d/sql/25_platform_databases.sql
  ```
- Exporter grants are AUTOMATIC: the core service `platform-exporter-grants` (`bootstrap/platform-exporter-grants.sh`, a loop with
  `restart: unless-stopped`, shipped in the S3 bundle with the SQL) polls database `platform` every 30 s
  (`GRANTS_POLL_SECS`). While `alembic_version` or `event_log` is missing it logs `waiting for the platform migrations` once and
  keeps polling; when they exist, or when the columns of `event_log`/`cases` change after a later migration, it applies
  `26_platform_exporter_grants.sql` (idempotent, `ON_ERROR_STOP`) and logs `exporter grants applied`. It has no healthcheck and
  nothing depends on it, so `pulso-stack`'s `up -d --wait`/`wait_healthy` never block on it. Check:
  `sudo docker compose -p pulso logs platform-exporter-grants`. Fallback by hand (same file, safe to repeat):
  ```bash
  sudo docker compose -p pulso exec postgres psql -v ON_ERROR_STOP=1 -U pulso_master -d platform -f /docker-entrypoint-initdb.d/sql/26_platform_exporter_grants.sql
  ```

## Sizing (core host `m7i-flex.large`, 2 vCPU, 8 GiB)

Container limits: postgres 2048 MiB (`shared_buffers` 512 MB, `effective_cache_size` 1536 MB, `work_mem` 8 MB,
`max_connections` 200), agent-core 768, core-runtime 768, tool-service 1024, gateway 128, exporter 128; one-shot migrations 256 each,
one at a time. About 4.9 GiB of limits, about 3 GiB left for the kernel, Docker, page cache and the SSM agent. Budget per service
pool, worst case (everything at its pool maximum at once):

| Consumer | Connections |
|---|---|
| agent-core, 2 databases x pool 24 | 48 |
| platform API | 20 |
| core-runtime (legacy, profile-disabled, counted anyway), 2 x 5 | 10 |
| engine | 10 |
| tool-service | 5 |
| llm-gateway | 5 |
| `superuser_reserved_connections` | 3 |
| one-shots (migrations, bootstrap, grants, exporter) | 6 |
| **Total** | **107** |

107 of `max_connections` 200 is 54 percent; the contract keeps at least 15 percent headroom (`tests/test_agent_core_serve_contract.py`, budget <= 170). With `max_connections` 100 and agent-core pools of 24 the worst case would not leave headroom. Raising to 200 only grows the lock and proc tables (a few MB); `shared_buffers` and `work_mem` (per sort operation, not per connection) are unchanged and the 2048 MiB container limit holds because real concurrency is bounded by the in-flight caps, not by `max_connections`.

## Backup and restore

Daily EBS snapshots of the Postgres volume (DLM) are the base. Logical dump (consistent, per database, restorable on a laptop):

```bash
# on the core host
sudo install -d -m 700 /srv/data/backups
for db in agent_runtime agent_eval platform tools pulso core_runtime core_eval; do
  sudo docker compose -p pulso exec -T postgres pg_dump -U pulso_master -Fc "$db" > "/srv/data/backups/$db-$(date +%F).dump"
done
```

Restore drill (once, into a scratch container, never over a live database): `pg_restore --list` each dump, then
`createdb scratch && pg_restore -d scratch <dump>` and count rows of `event_log`. Copy dumps to `s3://<bucket>/core/backups/`
(the core role may write `core/*`). Automating the dump and the upload is an open item (the start script lives in `user_data`,
whose change replaces the instance: do it as a compose sidecar).

## Network

Postgres is published on 5432 on the core host; the core security group admits 5432 from the platform and engine security
groups only (no CIDR). Inside the VPC there is no TLS; the engine and platform connect with `sslmode=disable`-equivalent DSNs.
