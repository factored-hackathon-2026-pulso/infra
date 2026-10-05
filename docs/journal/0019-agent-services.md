# 0019 agent services: agent-core serve and tool-service on the core host

- Why: support-platform needs `agentcore serve` (runs, sessions, registry API, HTTP tools); the core host ran only the
  engine's `core-runtime` (improvement-engine `core-bridge`, agent-core pinned at c814c2b), and `tool-service` had no
  image repository, bundle, secret or data path. Review notes: `factored/revision-despliegue-aws.md` (outside the repo).
- What: `agent_services_enabled` (default false) adds `compose.agents.yaml` on core (agent-core-migrate, agent-core on
  8001, tool-service internal) and on platform (API on 8000 for grant_active, agent-core URL, key files); `AGENT__`,
  `TOOLS__` and `FILES__<SVC>__<NAME>` secret keys (files written 0400 uid 10001 under `/run/pulso/files`); databases
  `agent_runtime`/`agent_eval` (`20_agent_databases.sql`); core role reads `lake/publish/*`; `gold_restricted` joins
  the PII deny of the bucket policy (always, not only with the flag); SG paths platform->core:8001 and
  core->platform:8000; Caddy refuses `/api/v1/internal/*`; ECR repositories and build/deploy entries for
  `agent-core-serve` and `tool-service`; `set-secret` accepts AGENT, TOOLS, DB and FILES keys (now case-sensitive).
- TDD: RED then GREEN per module. Commands and results (Terraform 1.16.4 local; CI pins 1.10.5, not run):
  - `terraform test` in `modules/hackathon_network` 18 passed, `modules/hackathon_iam` 18, `modules/hackathon_data` 23,
    `modules/hackathon_compute` 32, `envs/hackathon` 22, `bootstrap` 21; `terraform fmt -check -recursive terraform` clean.
  - `python -m unittest discover -s tests`: 213 tests, OK (1 skipped), including `tests/test_agent_services_contract.py`.
  - Pester 3.4 on Windows PowerShell 5.1, `scripts/tests/aws-prod.Tests.ps1`: 80 passed, 6 failed; the same 6 fail on
    origin/main with this shell (check, images, deploy), so they are not caused here. Not run on PowerShell 7.
  - Rendered `prepare.sh` for core and platform passes `bash -n`.
- Not verified: nothing applied; the compose overrides were not started (no Docker run here); the agent-core image
  cannot start `serve` until transcript, calibration and classifier are real (agent-core work in progress).
