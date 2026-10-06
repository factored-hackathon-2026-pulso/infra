# The improvement loop on the engine host: `pulso loop` as a systemd one-shot

One run of the improvement loop (cells, sensor, Scout/Verifier/Builder, regression proof on agent-core, registry write as the builder principal, announce to the platform) is the `pulso loop` subcommand of the engine image: a process of its own, no HTTP service. Infra runs it from a systemd timer. Contract: improvement-engine `docs/dev/ENGINE_PROD.md` (ENGPROD); the exact lines were asked in `ASK_infra_engine_loop_env`. Off by default (`engine_loop_enabled = false`), needs `agent_services_enabled`, nothing applied, nothing run.

Checked by `tests/test_engine_loop_contract.py` and the Terraform tests of `terraform/envs/hackathon` and `hackathon_compute`.

## What is installed (engine host, only with the variable)

| Piece | Where | Role |
|---|---|---|
| `compose.loop.yaml` | `/srv/stack` (bundle) | service `pulso-loop`, profile `loop` (never part of `up`), `command: ["loop"]` |
| `pulso-loop.service` | `/etc/systemd/system` | `Type=oneshot`: sync inputs, `docker compose run --rm pulso-loop`, status hook |
| `pulso-loop.timer` | same + drop-in `interval.conf` | `OnBootSec=10min`, then `engine_loop_interval` (default 6h) after each run ends |
| `pulso-inputs-sync` | `/usr/local/bin` | S3 inputs mirror (below) |
| `pulso-loop-status` | `/usr/local/bin` | exit-status handling and alert marker |
| `pulso-loop-failed.service` | `/etc/systemd/system` | `OnFailure=` marker `/srv/data/loop/FAILED` |

## Environment of the job (names; values are literals, SSM or secrets)

| Name | Value / source |
|---|---|
| `PULSO_LOOP_COMMAND` | literal `loop` (the entrypoint is `pulso`; the compose `command` is `["loop"]`) |
| `PULSO_REGISTRY_ENV` | literal `shared` |
| `PULSO_REGISTRY_VIA` | literal `api` |
| `PULSO_REGISTRY_AUTH` | literal `mint` |
| `PULSO_SERVICE_SEED_HEX` | secret `PULSO__PULSO_SERVICE_SEED_HEX` (Terraform-generated Ed25519 seed, 64 hex) in `pulso.env` |
| `PULSO_SERVICE_KID` | SSM `/pulso/engine/pulso/PULSO_SERVICE_KID` (`pulso-engine-<suffix>`) in `pulso.env` |
| `PULSO_SERVICE_CRED_TTL_S` | literal `300` |
| `PULSO_REGISTRY_ADDR` / `PULSO_CORE_ADDR` | SSM, core private IP and 8001 (the registry address falls back to `PULSO_CORE_ADDR`) |
| `PULSO_CELLS_SOURCE` | `.env` from `engine_loop_cells_source` (`bank` default; `e0`, `synthetic`) |
| `PULSO_PROFILE` | `.env` from `engine_loop_profile` (`standard` default; `demo` only with `synthetic`, enforced by a variable validation and by the engine) |
| `PULSO_LOOP_INPUTS_DIR` | literal `/var/lib/pulso/inputs` (the S3-synced mirror, mounted read-only; file `cells.ndjson`) |
| `PULSO_WORK_DIR` | literal `/var/lib/pulso/work` (lock, records, receipts, results; `/srv/data/pulso` read-write) |
| `PULSO_LLM_GATEWAY`, `PULSO_LLM_GATEWAY_ADDR`, `PULSO_LLM_GATEWAY_KEY` | literal `enabled`, SSM core IP and 8080, secret `PULSO__PULSO_LLM_GATEWAY_KEY` |
| `PULSO_EVAL_BEFORE_ANNOUNCE` | literal `on` |
| `PULSO_PLATFORM_URL`, `PULSO_PLATFORM_SERVICE_TOKEN` | SSM (with `platform_database_enabled`) and secret `PULSO__PULSO_PLATFORM_SERVICE_TOKEN`; announce is on only when both are set |
| `PULSO_LOOP_LOCK_TTL_S` | literal `10800`, above the unit's 2 h `TimeoutStartSec` |

Dropped from the old slot (not read by `pulso loop`): `PULSO_CORE_PORT`, `PULSO_MODEL_PORT`, `PULSO_CORE_URL`, `STEPS_RUNNER_EXE`. Left unset (engine defaults): `PULSO_LOOP_CELLS_FILE`, `PULSO_LOOP_MAX_FINDINGS`, `PULSO_LOOP_MAX_EXPLORATORY`, `PULSO_ALLOW_DERIVED_AGGREGATES`, `PULSO_NEW_AGENT_ADMIN`, `PULSO_REGRESSION_*`, `PULSO_EVAL_TIMEOUT_SECS` (engine default 900 s covers copiloto-asesor-suite, which takes over 180 s; set it only to go longer), `PULSO_SERVICE_PRINCIPAL_ID`, `PULSO_LOOP_RUN_ID`.

### Credentials: minted, never static

The engine mints a short-lived Ed25519 credential (compact JWS, `type=builder`, `roles=["constructor"]`, 300 s) on EVERY registry request from the seed and the kid, and the engine's public key is in agent-core's staff-keys under that kid (Terraform generates the pair; rotation in [agent-core-serve](agent-core-serve.md#7-rotation-of-the-engine-key-a5)). There is no `PULSO_REGISTRY_TOKEN` anywhere in the bundle, the secret keys or SSM; a static token would expire in minutes against `serve`. The loop refuses `PULSO_REGISTRY_CREDENTIAL=standin` with minting.

## Exit status handling (systemd)

| Exit | Meaning | Unit |
|---|---|---|
| 0 | finished, every finding closed | success; clears the `FAILED` marker |
| 75 | another run holds `loop.lock`, nothing done | `SuccessExitStatus=75` |
| 143 | SIGTERM (stop, shutdown) | `SuccessExitStatus=143 SIGTERM`: clean. The engine does not trap SIGTERM, so `pulso-loop-status` removes the orphaned `loop.lock` (only when no loop container is left) so the next run is not blocked until the TTL |
| 3 | finished with an infrastructure failure (registry unreachable or unauthorized, evaluation `failed_infra`, model unavailable) | FAILURE and ALERT: journal priority `err` (`journalctl -t pulso-loop -p err`), `/srv/data/loop/FAILED`, `engine/loop/status/last.json`; `Restart=on-failure` re-runs after 5 minutes, up to 3 times in 6 hours, and a re-run resumes the per-finding records |
| 2 | refused configuration (a named variable) | `RestartPreventExitStatus=2`: not retried; also an alert; fix the variable named in the log |
| 1, other | could not run (inputs not synced, work dir, model setup) | failure, retried like 3 |

After the retries are used up the unit is `failed` and `pulso-loop-failed.service` leaves a second marker. No SNS topic or CloudWatch alarm is wired: the alert is the journal line plus the marker (an alarm on the `err` line needs `enable_cloudwatch_agent` and a metric filter, not done).

## The inputs mirror

`/srv/data/inputs` is refreshed by `pulso-inputs-sync` before every run, with the host role, and mounted read-only into the job at `/var/lib/pulso/inputs`:

1. `s3://<bucket>/engine/inputs/` is mirrored into a staging directory (operator-provided inputs such as E0 or a synthetic `cells.ndjson`).
2. If the auto-loader published bank cells (`lake/gold_analytics/bank_cells/latest.json` and `<run>/cells.ndjson`, [auto-loader](auto-loader.md)), that file becomes `cells.ndjson` after its sha256 matches the manifest and `check_cells_k.py` (k >= 10, allowed keys only, the loader's own gate script) passes AGAIN on the engine host. The loader is not duplicated: this script only copies and re-checks what it produced.
3. Staging must hold a non-empty `cells.ndjson`; then it replaces the mirror. A failed sync keeps the previous mirror and warns; no mirror at all fails the unit (journal `err`).

The engine role reads `lake/gold_analytics` and `engine/*` only (`engine_host_can_load` stays false): never `landing/` or the restricted zone.

## Turn it on

Prerequisites (blockers if missing): `agent_services_enabled = true` with agent-core serve healthy; the engine image built from the ENGPROD image change (python3, PyYAML and `scripts/regression/` inside; without them, with `PULSO_EVAL_BEFORE_ANNOUNCE=on` the job exits 2 before any model call); bank cells either from the loader or uploaded to `engine/inputs/cells.ndjson`.

```
engine_loop_enabled      = true
engine_loop_interval     = "6h"
engine_loop_cells_source = "bank"   # synthetic only with engine_loop_profile = "demo"
```

Adds `compose.loop.yaml`, the `loop/` scripts and units to the engine bundle (and `loader/check_cells_k.py` if the loader is off). Changing the engine `user_data` replaces the engine host on the next apply (data volume persists), like every start-script change; plan review in [deploy-readiness](deploy-readiness.md).

Manual run: `sudo systemctl start pulso-loop`; check `pulso loop --check` (validates configuration, prints one JSON line, takes no lock) with `docker compose -p pulso --project-directory /srv/stack run --rm pulso-loop loop --check`.

## What is not verified

Nothing ran: no `pulso loop` process, no systemd, no S3. Unconfirmed: that `docker compose run` returns the container's exit code through systemd and `SuccessExitStatus` (documented behaviour, not exercised), that `Restart=on-failure` on a `Type=oneshot` unit behaves as intended on the host's systemd, that `PULSO_REGISTRY_ADDR` falls back to `PULSO_CORE_ADDR` as the ASK states, the shape of the loader's `latest.json` (`run` and `sha256` fields, read from `pulso-loader.sh`), and the engine image contents.
