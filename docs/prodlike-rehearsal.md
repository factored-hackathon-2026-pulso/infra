# Local prod-like rehearsal (`scripts/prodlike/`)

A laptop rehearsal of the EC2 host stacks with Podman, before any real deployment. It renders the **real** bundles in
`deploy/hackathon/` (same compose files, same health checks, same `depends_on`, same env file names, same image variables)
into `.prodlike/` (git-ignored) and changes only what a laptop cannot do. It does not talk to AWS, does not need
credentials, and prints no secret.

```
# once per checkout of each service (one image at a time, RAM checked; Python images need about 1.5 GB free, the Rust engine about 3 GB)
python scripts/prodlike/prodlike.py build gateway --src <llm-gateway checkout>
python scripts/prodlike/prodlike.py build tools   --src <tool-service checkout>
python scripts/prodlike/prodlike.py build agent   --src <agent-core checkout>        # the Dockerfile of agent-core, linux/amd64
python scripts/prodlike/prodlike.py build engine  --src <improvement-engine checkout>
python scripts/prodlike/prodlike.py state --agent-core <agent-core checkout>          # synthetic publication + agent-core TEST keys, calibration, classifier
# one command up (render + start + wait healthy, the rule of deploy-stack.sh); secrets come from KEY=VALUE files, only the contract's names are read
python scripts/prodlike/prodlike.py up --env-file <llm-gateway.env> --env-file <agent-core.env>   # add --podman-run on machines without a pids cgroup
python scripts/prodlike/prodlike.py seed --agent-core <agent-core checkout> --model xiaomi/mimo-v2.6-flash   # four fixture agents into the registry
python scripts/prodlike/prodlike.py smoke [--live] [--strict]
python scripts/prodlike/prodlike.py chaos postgres|gateway-down|tools-down|serve-restart|serve-start-db-down|serve-env-missing [--var NAME]
python scripts/prodlike/prodlike.py loop --engine-src <engine checkout>               # one `pulso loop`, planted SYNTHETIC cells
uv run --project <agent-core checkout> python scripts/prodlike/exercise_serve.py --prefix <prefix>   # turns, registry flow, export, load
python scripts/prodlike/prodlike.py down --volumes
```

`PULSO_STACK_PREFIX` (default `infb`) names the compose projects (`<prefix>-core`, `<prefix>-engine`), the shared network,
the volumes and the local images, so lanes do not collide. Each lane picks its own prefix. `PRODLIKE_COMPOSE` overrides the
compose command (default `podman compose`). Requirements: Python with PyYAML, Podman with a compose provider.

## 1. What is the same as production

| Aspect | How it is kept |
|---|---|
| Compose files | the files of `deploy/hackathon/{core,engine}` merged in the order Terraform uses; services are parsed, never re-written by hand |
| Health checks, restart, limits, user, command, `depends_on` | copied unchanged; a test asserts equality per service |
| Image references | still variables (`GATEWAY_IMAGE`, `TOOLS_IMAGE`, `PULSO_IMAGE`, ...) resolved from a rendered `.env`, as on the host |
| Env files | `common`, `gateway`, `tools`, `db`, `pulso` with the production variable NAMES (`scripts/prodlike/env_contract.json`); a test checks every key against Terraform, so the contract cannot drift silently. Each host gets only its slice, like `pulso-stack-prepare` |
| Gateway address | the engine calls the gateway by IP literal on a shared network (fixed address), as in production where it is the core private IP |
| Engine edge | the engine is reached through the Caddy proxy with `X-Origin-Verify`, the `/pulso` prefix kept, `/internal` hidden |
| Wait rule | every container healthy or exited 0, twice in a row, within the timeout: the logic of `deploy-stack.sh` |

## 2. Deviations (printed by `render`, never hidden)

* absolute host paths (`/srv/...`, `/run/pulso/...`) become named volumes or a local directory. `up` gives the volumes that
  `prepare.sh.tftpl` chowns to uid 10001 to uid 10001 (parsed from that file), but a named volume over a directory that exists in the
  image inherits the image's ownership, so for the engine the **ownership bug is covered by `tests/test_run_health_contract.py`, not by this rehearsal**;
* if crun cannot set cgroup limits (this project's WSL machines), `up` re-renders without `mem_limit` and with `pids_limit: 0` and prints it;
* published ports bind `127.0.0.1` at 18080 (engine proxy), 18081 (gateway), 15432 (Postgres);
* secrets are random local values; `OPENROUTER_API_KEY` and `JEV_API_KEY` are copied only from `--gateway-env-file` if given,
  otherwise `CHANGE_ME` (the paid gateway call is then skipped or fails visibly);
* the engine connects to Postgres as the master role. In production the application role cannot log in until the human
  database steps (`docs/db-bootstrap.md`) have run; that ordering gap is not rehearsed;
* one machine, one network: the three-host security groups, CloudFront and DNS are not modelled;
* S3, SSM and Secrets Manager do not exist: the tool-service has no data publication, so its `/readyz` is 503 (reported, not a failure).

## 3. Slots (images that do not exist yet)

A service whose image variable has no local image is **dropped from the rendered stack and listed as a slot**; its `depends_on` edges are
removed and reported. agent-core `serve` is no longer a slot: build it from its own Dockerfile (`build agent`). Today:

| Slot | Needs | Owner brief |
|---|---|---|
| platform backend and SPA (`SUPPORT_API_IMAGE`, `SUPPORT_WEB_IMAGE`) | images, Postgres instead of SQLite, health | platform brief. Meanwhile `render` ADDS a **double** of the platform grant endpoint (`scripts/prodlike/grants_stub.py`) as service `platform` with the alias `platform.pulso.internal`, so serve's real `http_grant_active` has something to call; it says every grant is active unless listed in `files/grants/revoked`. Never use it to judge a revocation |
| core runtime (`CORE_IMAGE`) | core-bridge image; not part of the improvement loop (ADR 0009) | engine repo `core-bridge` |
| engine host (`PULSO_IMAGE`) | the engine image; without it the proxy alone is not started, the env files are still rendered (smoke and `loop` read the seed) | this repo |
| OTLP forwarder sidecars | `FORWARDER_IMAGE` from `docker/otlp-forwarder.Dockerfile`; `render --forwarder` | this repo |

When the image exists, build or load it, add it to `.prodlike/images.json` (variable name to local reference) or `build` it, and `render`
keeps the service with its real dependencies (a test renders `agent-core` and checks them).

### agent-core serve in the stack

The rendered `agent-core` and `agent-core-migrate` are the compose services of `deploy/hackathon/core/compose.agents.yaml` unchanged
(command, `AGENT_SERVE_ARGS` from the Terraform default, healthcheck on `/readyz`, owner-role migrate with `--app-role agent_app`,
`user 10001`, `stop_grace_period`). Its inputs come from `state` (never from AWS): agent-core's TEST identity keys, with the **engine's public
key added to `staff-keys` under `pulso-engine-local`** (derived by `render` from the generated `PULSO_SERVICE_SEED_HEX`, so the engine can mint a
`builder` credential), synthetic calibration and classifier artifacts, and a **synthetic data-pipeline publication** (two invented customers,
built inside the tool-service image). The field grants are a synthetic list for the `advisor_view` purpose; the field-classification overlay is
agent-core's own plus the slot names its flows need (`OVERLAY_GAPS`, reported to agent-core).

## 4. The smoke test

`smoke` prints one line per step and exits non-zero on any failure.

| Step | Status today |
|---|---|
| gateway liveness through the image probe and the published port | implemented |
| gateway refuses a call without a bearer (401) | implemented |
| gateway authenticated call as consumer ENGINE with `mimo-v2.6-flash` (a few cents) | implemented, only with `--live` |
| Postgres healthy, init created `core_runtime`, `core_eval`, `pulso` | implemented |
| tool-service healthy, catalogue of 7 tools with the real bearer, `/readyz` reported | implemented |
| agent-core: image probe healthy, `/healthz`, `/readyz` (per-dependency JSON), `/version` | implemented |
| agent-core: `AGENTCORE_ALLOW_DOUBLES` / `ALLOW_DEMO` absent from the container env and the startup line says `mode=production` | implemented |
| agent-core runs as uid 10001 | implemented |
| the engine's builder credential, minted in pure Python from the seed exactly as the engine does: create a proposal 201, approve 403, a credential signed by another key 401 | implemented |
| engine ready through the proxy, 403 without the origin header, `/internal` hidden, proxy `/healthz` | implemented when the engine image is in the stack, else a slot |
| loop: detect, propose, prove | `prodlike.py loop` (engine image, planted synthetic cells, minted credential, mimo flash and pro); not part of `smoke` because it costs model calls |
| loop: announce, approve, publish, release, outcome | **slots**: they need the platform (and a human approver). The engine is never allowed to approve, publish or promote; `smoke` proves the 403 |

`--strict` turns slots into failures. The summary line states that this is not the full loop. `chaos` stops or restarts one dependency and prints what it observed: `postgres` (agent-core and engine `/readyz` 503 while liveness stays 200,
recovery without a manual step), `gateway-down` (serve not ready, alive), `tools-down` (serve stays ready and reports it), `serve-restart`,
`serve-start-db-down` (serve started while Postgres is down stays alive and becomes ready by itself), `serve-env-missing` (exit 2 naming the
variable, no value printed); `gateway` kills the gateway and expects the restart policy to bring it back healthy.

## 5. Why `up --podman-run` exists

On this project's WSL Podman machines no container can start through the compose API: the daemon applies a default pids limit that crun cannot
enforce here (`controller pids is not available`), even with `pids_limit: 0` or `-1`, and `docker-compose` cannot send `--pids-limit=0`. `podman run`
can. `up` therefore falls back by itself (or with `--podman-run`) to starting the SAME rendered services with `podman run --pids-limit=0`, honouring
image, command, entrypoint, restart, user, env files, ports, volumes, `shm_size`, `stop_grace_period`, health checks (passed as JSON arrays) and
`depends_on` conditions (`service_healthy`, `service_completed_successfully`), and labelling them like compose so `smoke`, `chaos` and the wait rule
find them. Services without a fixed address get one from `.50` up so they cannot take the fixed `.10` gateway, `.11` agent-core and `.12` tool-service.
Memory limits are dropped in that mode (reported). Nothing about the machine is reconfigured.

Local secrets are derived from `.prodlike/secrets.seed`, so a re-render keeps the passwords of an already initialised Postgres volume;
`down --volumes` removes the seed together with the volumes.

## 6. Exercised status

The live results of the serve rehearsal (checks, counts, defects and owners) are in
`docs/reports-claude/PRODLIKE_SERVE_RESULTS_2026-10-05.md` of the working tree (not versioned here). The offline tests
(`tests/test_prodlike.py`, `tests/test_prodlike_serve.py`) pin the rendering, the contract, the fallback runner and the Ed25519 vectors.
