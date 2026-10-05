# 0024 Prod-like rehearsal with agent-core `serve` in the stack (PRODLIKE, 2026-10-05)

Lane PRODLIKE, branch `claude/infra-prodlike-serve` from `origin/main` 9f06c17 (PR 40 merged). Local synthetic only: no AWS call, no `terraform apply`, no
real data, no secret printed (values only in child process environments, from the operator's KEY=VALUE files, names read from `env_contract.json`).

## What changed

* `scripts/prodlike/prodlike.py`: `build agent` (agent-core's own Dockerfile, amd64, docker format, GIT_SHA, time printed), `state` (synthetic publication
  built inside the tool-service image + agent-core `serve_state.py`), `up` renders agent-core and its migrate job from `compose.agents.yaml` unchanged,
  starts them (falls back to `podman run --pids-limit=0` on machines without a pids cgroup), `seed` (fixture registry, optional model override), `smoke`
  (agent-core probes, production mode, uid, engine builder credential create 201 / approve 403 / forged 401), `chaos` (postgres, gateway-down, tools-down,
  serve-restart, serve-start-db-down, serve-env-missing), `loop` (one `pulso loop` from the engine image, planted synthetic cells). Per-prefix host ports,
  deterministic local secrets (a re-render keeps the passwords of an initialised Postgres volume), fixed addresses that automatic ones cannot steal.
* `scripts/prodlike/{ed25519,synthetic_publication,grants_stub,exercise_serve}.py`: pure-Python RFC 8032 (staff-keys public key from the engine seed, builder
  signature), the synthetic data-pipeline publication, a DOUBLE of the platform grant endpoint (service `platform`, alias `platform.pulso.internal`), and the
  exercise driver (turns, registry flow, export, concurrency, restart mid-run) that runs under agent-core's Python.
* `env_contract.json`: the `agent` env file (10 names) and the five `FILES__AGENT__*` files.
* `deploy/hackathon/core/compose.agents.yaml`: `stop_grace_period: 30s` on agent-core (serve's own grace is 25 s; Docker's default 10 s would kill a turn in flight).
* `deploy/hackathon/engine/compose.loop.yaml`: the loop job now matches engine `docs/dev/ENGINE_PROD.md` (command `loop`, its env), still opt-in and unwired.
* Docs: `docs/prodlike-rehearsal.md`, `docs/run-and-health.md`. Tests: `tests/test_prodlike_serve.py` (new), `tests/test_run_health_contract.py` (loop job).

## Commands and results

```text
python -m unittest discover -s tests          # 322 tests, OK (1 skipped)
python -m unittest tests.test_prodlike tests.test_prodlike_serve tests.test_run_health_contract tests.test_docs_consistency
```

Live evidence (counts, defects, owners): `docs/reports-claude/PRODLIKE_SERVE_RESULTS_2026-10-05.md` in the working tree (not versioned).
Terraform was not touched, so no `terraform test` was run.
