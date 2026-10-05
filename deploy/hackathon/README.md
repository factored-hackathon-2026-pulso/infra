# Hackathon compose bundles

Three hosts, one bundle each (`core/`, `platform/`, `engine/`), all private subnets. CloudFront with a VPC origin
terminates TLS and sends HTTP to port 80 of the platform proxy and port 8080 of the engine proxy. Nothing else is public.

| Host | Services (mem MB) | Published |
|---|---|---|
| core | core-migrate 256 (one-shot), core-runtime 768 (`agentcore serve`, agent-core's own image), llm-gateway 128 | core-runtime 8000 (SG: platform+engine only), llm-gateway 8080 (SG: engine only) |
| platform | support-platform-api 512, support-platform-web 64, proxy 64, internal-proxy 32 | proxy 80, internal-proxy 8081 (SG: core only) |
| engine | pulso 512 (`pulso healthcheck`, 70 s stop grace), proxy 64 | proxy 8080 |

The core host runs agent-core's image built from agent-core's own Dockerfile (ADR 0009, ADR 0003); `core/field-overlay.json` is
the field-classification overlay mounted into it. The Ed25519 key documents are secret keys (`CORE__IDENTITY_KEYS_JSON`,
`CORE__STAFF_KEYS_JSON`, `SUPPORT__AGENT_KEYS_JSON`) rendered into the service env files and written to `/tmp` by the service
entrypoint, so the start script (part of `user_data`) is not involved.

Routes: platform proxy `/api/*` (incl. `/api/v1/ws`) -> api:8000, `/` -> web:80, `/internal*` 404;
engine proxy `/pulso/*` -> pulso:8080, `/internal*` 404. `/healthz` answers on both proxies.

Files on a host: `/srv/stack` is synced from S3 `engine/deploy/<workload>/` (compose, Caddyfile, `.env` rendered by Terraform).
`/run/pulso/env/<svc>.env` (tmpfs, 0600) is generated at every start from the host's slice of the ONE Secrets Manager secret
(JSON keys `<SERVICE>__<VAR>`) plus non-secret SSM values under `<ssm_prefix>/<workload>/<svc>/<VAR>`. Never commit values.

Operate: `sudo systemctl stop|start pulso-stack`; Terraform `enabled` map stops an instance; logs by `docker compose -p pulso logs -f <svc>`.
Support-platform stays single instance and in non-prod settings (prod refuses without an email adapter).
