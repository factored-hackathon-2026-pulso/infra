# Local prod-like rehearsal (`scripts/prodlike/`)

A laptop rehearsal of the EC2 host stacks with Podman, before any real deployment. It renders the **real** bundles in
`deploy/hackathon/` (same compose files, same health checks, same `depends_on`, same env file names, same image variables)
into `.prodlike/` (git-ignored) and changes only what a laptop cannot do. It does not talk to AWS, does not need
credentials, and prints no secret.

```
python scripts/prodlike/prodlike.py render                    # inspect .prodlike/ first; lists slots and deviations
python scripts/prodlike/prodlike.py build gateway --src <llm-gateway checkout>     # one image at a time, RAM checked
python scripts/prodlike/prodlike.py build tools   --src <tool-service checkout>
python scripts/prodlike/prodlike.py build engine  --src <improvement-engine checkout>   # needs about 3 GB free RAM
python scripts/prodlike/prodlike.py up                        # render + compose up + wait healthy (deploy-stack.sh rule)
python scripts/prodlike/prodlike.py smoke [--live] [--strict]
python scripts/prodlike/prodlike.py chaos postgres            # or: gateway
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

* absolute host paths (`/srv/...`, `/run/pulso/...`) become named volumes or a local directory; volume ownership therefore comes
  from the image, so the **ownership bug class is covered by `tests/test_run_health_contract.py`, not by this rehearsal**;
* published ports bind `127.0.0.1` at 18080 (engine proxy), 18081 (gateway), 15432 (Postgres);
* secrets are random local values; `OPENROUTER_API_KEY` and `JEV_API_KEY` are copied only from `--gateway-env-file` if given,
  otherwise `CHANGE_ME` (the paid gateway call is then skipped or fails visibly);
* the engine connects to Postgres as the master role. In production the application role cannot log in until the human
  database steps (`docs/db-bootstrap.md`) have run; that ordering gap is not rehearsed;
* one machine, one network: the three-host security groups, CloudFront and DNS are not modelled;
* S3, SSM and Secrets Manager do not exist: the tool-service has no data publication, so its `/readyz` is 503 (reported, not a failure).

## 3. Slots (images that do not exist yet)

A service whose image variable has no local image is **dropped from the rendered stack and listed as a slot**; its
`depends_on` edges are removed and reported. Today:

| Slot | Needs | Owner brief |
|---|---|---|
| agent-core serve (`AGENT_IMAGE`) | `/healthz` and `/readyz`, image, migrations, env doc | agent-core brief, section A3 and A4 |
| platform backend and SPA (`SUPPORT_API_IMAGE`, `SUPPORT_WEB_IMAGE`) | images, Postgres instead of SQLite, health | platform brief |
| core runtime (`CORE_IMAGE`) | core-bridge image; not part of the improvement loop (ADR 0009) | engine repo `core-bridge` |
| OTLP forwarder sidecars | `FORWARDER_IMAGE` from `docker/otlp-forwarder.Dockerfile`; `render --forwarder` | this repo |

When the image exists, build or load it, add it to `.prodlike/images.json` (variable name to local reference) or `build` it, and
`render` keeps the service with its real dependencies (a test renders `agent-core` and checks them). Nothing else changes.

## 4. The smoke test

`smoke` prints one line per step and exits non-zero on any failure.

| Step | Status today |
|---|---|
| gateway liveness through the image probe and the published port | implemented |
| gateway refuses a call without a bearer (401) | implemented |
| gateway authenticated call as consumer ENGINE with `mimo-v2.6-flash` (a few cents) | implemented, only with `--live` |
| Postgres healthy, init created `core_runtime`, `core_eval`, `pulso` | implemented |
| tool-service healthy, catalogue of 7 tools with the real bearer, `/readyz` reported | implemented |
| engine ready through the proxy, 403 without the origin header, `/internal` hidden, proxy `/healthz` | implemented (needs the engine database steps; see the deviation) |
| loop: detect, propose, prove, announce, approve, publish, release, outcome | **slots**: all need agent-core serve and the platform; detect also needs the engine loop runner (`steps_cli` is not in the engine image) pointed at this stack |

`--strict` turns slots into failures. The summary line states that this is not the full loop. `chaos postgres` stops the
database, expects the engine `/readyz` to be 503 while the proxy `/healthz` stays 200, restarts it and expects recovery;
`chaos gateway` kills the gateway and expects the restart policy to bring it back healthy.

## 5. Exercised status of this design

Written and unit-tested offline (`tests/test_prodlike.py`: rendering invariants, secrets contract, health rule, slots, RAM
guard). **Not run against Podman by this change**: the host had less than 1 GB of free RAM and other lanes' stacks running, and a
Rust image build needs about 3 GB; the first live `up` is the next step for whoever has the headroom.
