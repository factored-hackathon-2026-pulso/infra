# 0024 Wire agent-core serve, the engine loop and the OTLP forwarder; deploy-readiness (lane INFRA-C)

Branch `claude/infra-wire-serve-loop`, from `origin/main` 9f06c17 (PRs 37 to 42 merged). Offline only: no apply, no AWS call, no credential,
no secret value read or printed, `D:\Nexus` untouched, `TF_PLUGIN_CACHE_DIR` unset, one test suite at a time, nothing under
`scripts/prodlike` or `docs/prodlike-rehearsal.md` edited (lane PRODLIKE owns them).

Sources: the three INFRA reports and the two asks of 2026-10-05; agent-core `main` (fresh shallow clone, PRs 62 to 70: `docs/serve-env.md`,
`deploy/compose/`, `Dockerfile`, `agent_core/composition/schema_version.py`); improvement-engine `main` (`docs/dev/ENGINE_PROD.md`,
`scripts/o11y/otlp_forwarder.py`).

## What changed

1. **Core host** (docs/agent-core-serve.md): `compose.agents.yaml` rewritten to the serve-env contract. The core-bridge services
   (`core-migrate`, `core-runtime`, `core-exporter`) are put behind the profile `legacy-core-bridge`; `CORE_IMAGE` aliases the agent image so
   interpolation succeeds. serve gets only environment (no piece flags: the seven real pieces are its defaults), `/readyz` as container health
   with a 60 s start period, `stop_grace_period` 30 s above `AGENTCORE_SHUTDOWN_GRACE_SECONDS` 25, load caps by instance size
   (`local.agent_limits`), `AGENTCORE_AUTO_MIGRATE=0` with the explicit advisory-locked `agentcore migrate` one-shot ordered after a healthy
   Postgres (`compose.agents.postgres.yaml`) and `pulso-db-bootstrap` deliberately outside that chain. `agent-core-sweep` plus a 5 minute timer.
   The owner DSNs are blanked in serve's environment. `agent_serve_args` defaults to empty. New `agent_serve_agents`.
2. **Never doubles**: `AGENTCORE_ALLOW_DOUBLES` and `AGENTCORE_ALLOW_DEMO` are rejected by `agent_serve_args`, absent from every file, and the
   start script aborts if either reaches an env file. Test scans the bundle and the hackathon Terraform.
3. **Engine key rotation**: `engine_extra_key_suffixes`, `engine_active_key_suffix`, `engine_retire_base_key` in `hackathon_data`; a guard
   (`terraform_data` precondition) refuses to retire the key in use; `scripts/engine_key_rotation.py` merges the three rotated keys into a copy
   of the secret without printing a value. The start script now rewrites `/run/pulso/files/*` in place (no `rm -rf`), so serve's 5 second reload
   sees a rotated file through the bind mount (before, the directory inode changed on every prepare).
4. **Engine host** (docs/engine-loop.md): `compose.loop.yaml` per the ASK (profile `loop`, `command: ["loop"]`, `PULSO_REGISTRY_AUTH=mint`,
   `PULSO_REGISTRY_ENV=shared`, `PULSO_CELLS_SOURCE`, inputs read-only), `pulso-loop.service` (`SuccessExitStatus=75 143`,
   `RestartPreventExitStatus=2`, exit 3 alert through `pulso-loop-status`), a timer with the interval as a drop-in, and `pulso-inputs-sync`
   (mirror of `engine/inputs` plus the loader's bank cells, sha256 and k>=10 re-checked; the loader is not duplicated). Variables
   `engine_loop_enabled`, `engine_loop_interval`, `engine_loop_cells_source`, `engine_loop_profile`.
5. **OTLP forwarder** (docs/otlp-forwarder.md): sidecars in the network namespace of llm-gateway and agent-core (core) and pulso (engine),
   loop job in the same namespace when both features are on; Langfuse keys as secret names, base URL in SSM; content flags off by default.
   Variables `otlp_forwarder_enabled`, `otlp_trace_content`, `langfuse_base_url`. `otlp-forwarder` added to the ECR repositories, the deployer
   policies, the image builder and `aws-prod.ps1` (services and the `LANGFUSE` secret prefix).
6. **Deploy readiness** (docs/deploy-readiness.md): offline plan review, state key migration (documented only), secrets checklist, apply
   order, cost, rollback, and the support-platform blockers.

## Tests (commands run, foreground, one at a time)

See the PR description for the final counts. Suites: `python -m unittest discover -s tests`; `terraform test` in `modules/hackathon_compute`,
`modules/hackathon_data`, `envs/hackathon`, `bootstrap`; `terraform fmt -check -recursive terraform`. New: `tests/test_agent_core_serve_contract.py`,
`tests/test_engine_loop_contract.py`, `tests/test_otlp_forwarder_contract.py`, `hackathon_compute/loop.tftest.hcl`,
`hackathon_data/engine_key_rotation.tftest.hcl`, env tests in `terraform/envs/hackathon/wire.tftest.hcl`. Existing tests that asserted the
old wiring were updated in place (gateway port format, core-migrate chain, forwarder "not wired", loop slot, bootstrap repository list).

## Findings

* The bootstrap tftest already listed eight repositories while the default had nine (`data-pipeline` from PR 41); fixed together with the new one.
* `pulso-stack-prepare` deleted and recreated `/run/pulso/files` on every run: a bind-mounted directory then points to a deleted inode, so a
  rotated key would never reach a running serve. Fixed (in place).
* `docs/service-deployment.md` had corrupted PowerShell paths (`.\scriptsws-prod.ps1`); fixed where the new section sits.

## Not verified

No image built, nothing started, no AWS. Facts about serve come from reading agent-core. systemd behaviour (`Restart=` on a oneshot,
exit code through `docker compose run`), load-cap numbers and the 60 s start period are unconfirmed. Cost figures use remembered prices.
