# 0022 Shared Postgres per-service databases, engine to platform edge, IMDS hop limit, gateway port

- Why: decision of 2026-10-05, one Postgres on the core host for platform, agent-core and tool-service. Review of main found
  four mismatches: IMDSv2 hop limit 1 (containers cannot use the instance profile), llm-gateway not published although the engine
  targets core:8080, no engine -> platform path/env, no platform/tools databases or read-only exporter role.
- What: `platform_database_enabled` (default false, needs agent_services_enabled); `25_platform_databases.sql`,
  `26_platform_exporter_grants.sql`, init gating, secret keys, generated `PULSO__PULSO_PLATFORM_SERVICE_TOKEN`, SG
  engine -> platform:8000, SSM engine values (IP literals), Postgres sizing (max_connections 100, 2 GiB), hop limit 2,
  gateway `8080:8080`, `engine_host_can_load = false` in the tfvars example. `docs/shared-postgres.md`.
- TDD/tests: `tests/test_shared_postgres_contract.py`; new runs in hackathon_network, hackathon_compute, hackathon_data and
  envs/hackathon tftests (mock providers). Results: see PR description.
- Not verified: nothing applied; SQL not executed against a live Postgres; platform DSN/migrate names depend on support-platform.
