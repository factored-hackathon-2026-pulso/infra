# Hackathon compose bundle

Single-host stack (one EC2, private subnet, Amazon Linux 2023). CloudFront with a VPC origin
terminates TLS and sends HTTP to the proxy on port 80. Nothing else is published.

| Path | Upstream |
|---|---|
| `/api/*` (incl. `/api/v1/ws`) | support-platform-api:8000 |
| `/pulso/*` | pulso:8080 (console and debug API) |
| `/healthz` | proxy itself |
| `/` | support-platform-web:80 |
| any `/internal*` | 404 at the proxy; Core and gateway stay on the docker network |

Memory limits (MB): core-migrate 256 (one-shot), core-runtime 1024, core-exporter 256, llm-gateway 256,
support api 768, support web 64, pulso 1024, proxy 128 = 3776 < 8 GB.

## Files on the host

- `/srv/stack/compose.yaml`, `Caddyfile`, `.env` are synced by Terraform from S3 (`engine/deploy/` prefix).
- `/run/pulso/env/{common,core,gateway,support,pulso}.env` (tmpfs, 0600) are generated at every start by
  `/usr/local/bin/pulso-stack-prepare` from ONE Secrets Manager secret (JSON). Keys are named
  `<SERVICE>__<VAR>` (`COMMON__`, `CORE__`, `GATEWAY__`, `SUPPORT__`, `PULSO__`), e.g.
  `CORE__DATABASE_URL` becomes `DATABASE_URL=...` in `core.env`. Reconcile the names with lane B's
  `docs/secrets-keys.md`. Non-secret config is read from SSM under `ssm_prefix` (`/<svc>/<VAR>`) into the same files.
- Values are never logged and never committed.

## Operations

- Stop everything: `sudo systemctl stop pulso-stack` (gives pulso 70 s to drain). Start: `sudo systemctl start pulso-stack`.
- Whole host off: Terraform variable `enabled = false` stops the instance.
- Logs: `docker compose -p pulso logs -f <svc>` (json-file, 10 MB x 3 per container).
- Support-platform runs in non-prod settings (prod refuses without an email adapter) and must stay a single instance.
