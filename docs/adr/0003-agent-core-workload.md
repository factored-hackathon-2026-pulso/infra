# Agent Core as a deployed workload

Status: **Accepted** (proposed and merged in pulso-factored/infra#11; the scope documents were aligned in
journal 0010). Accepting the ADR creates no resources: see "Implementation status".

## Context

ADR 0001 and ADR 0002 scope this repository to the improvement engine and treat
Agent Core as an external product. Agent Core now has a bootable HTTP server
(`agentcore serve`) and needs a place to run in `staging` and `prod`. Rebuilding
the same network, database and secrets plumbing in a second repository would
split ownership of one AWS account.

## Decision

1. **Scope.** This repository also owns the Terraform/AWS infrastructure that
   *runs* Agent Core. It still does not own Agent Core's code, image build,
   schema, migrations or runtime behavior; those stay in `agent-core`.
2. **Shape.** One shared network/observability foundation per environment, plus
   one *workload* per service (`improvement-engine`, `agent-core`) that consumes
   it. Workloads do not share a database instance or a task role.
3. **Environments.** Unchanged: `staging` and `prod` only. `prod` remains the
   hackathon demo, not a banking deployment.
4. **Region.** `us-east-1` (N. Virginia) for both environments for now. This is
   provisional: where the decision-model provider (JEV) processes and retains
   data has no public answer, so the region must be revisited before any real
   customer data is involved.
5. **Engines.** ECS on Fargate and RDS for PostgreSQL are the engines already
   declared for the improvement service (see the deployment-status contract).
   Agent Core reuses those choices, which also match its own stack decision (no
   queues, Redis or vector store), with its own ECS service, task roles and
   database instance.
6. **Egress.** Agent Core must reach the LLM endpoint(s) and JEV over HTTPS, so
   it needs the `controlled_nat` egress profile with the destination-control and
   logging design that profile requires; `aws_private_endpoints_only` cannot
   serve it. That design is the existing "Controlled external egress" gap.
7. **No automated apply.** Unchanged from ADR 0002. Plan/apply automation, OIDC
   write permission and remote state remain separate reviewed slices.

## Ownership split

| Owned by `agent-core` | Owned by this repository |
|---|---|
| Dockerfile and image build | VPC, subnets, NAT, security groups |
| `/healthz` and `/readyz` endpoints | ECR repository |
| Schema scripts and the `agentcore migrate` command | ECS cluster, service, task definition (pinned to an image digest) |
| Configuration contract with fail-closed validation | RDS instance(s): the engine database and the registry evaluation database |
| `agentcore sweep`, graceful shutdown, timeouts, degraded mode, cost caps | Secrets Manager entries (names and encryption only) and KMS keys |
| Guard that refuses `AGENTCORE_ALLOW_DEMO` outside demo | Task and execution roles, GitHub OIDC trust |
| Image CI: build, test, publish digest | Load balancer or API Gateway, TLS, WAF |
| Load tests | Scheduled sweep (EventBridge launching an ECS task) |
| | One-off migration task definition |
| | Log groups, alarms, backups, OpenTelemetry collector |

## Interface contract between the repositories

Both sides must change this table in the same pair of pull requests.

1. **Image.** Agent Core publishes an immutable digest. This repository deploys
   only a digest, never a tag.
2. **Network.** The container listens on one port (default `8000`);
   `/healthz` is liveness and `/readyz` is readiness (checks PostgreSQL). Both
   are unauthenticated, live outside `/v1` and expose no data.
3. **Secrets.** Values are set out of band, never in Terraform state or Git.
   Terraform provisions the entries; the task injects them as environment
   variables:

   | Variable | Content |
   |---|---|
   | `AGENTCORE_REGISTRY_DSN` | PostgreSQL DSN for the engine and registry |
   | `AGENTCORE_EVAL_DSN` | DSN for the registry evaluation database |
   | `AGENTCORE_KEYS_FINGERPRINT`, `AGENTCORE_KEYS_TOKEN_MAP` | HMAC/encryption keys, `kid:base64` form |
   | `AGENTCORE_JEV_API_KEY` | JEV API key |
   | `LLM_ENDPOINTS` | JSON map of endpoint aliases (holds variable names only) |
   | One variable per LLM endpoint | The key named by `api_key_env` in `LLM_ENDPOINTS` |

4. **Plain configuration.** `AGENTCORE_SERVE_AGENTS`, host, port and the
   standard `OTEL_*` variables (for example `OTEL_EXPORTER_OTLP_ENDPOINT`) are
   ordinary task environment variables, as are `--keys-reload-seconds` (item 10)
   and the build-time `AGENTCORE_GIT_SHA` (item 9). The identity public-key file read by
   `--identity-keys` holds public keys only and is delivered as configuration.
5. **Forbidden in deployed environments.** `AGENTCORE_ALLOW_DEMO` must be unset.
   The service must exit non-zero, naming each missing piece, rather than start
   with test doubles. See "Implementation status" for why this cannot hold yet.
6. **Commands.** `agentcore migrate` (run as a one-off task before a service
   update) and `agentcore sweep --once` (run on a schedule).
7. **Egress hosts.** `api.typesafe.ai` and each host in `LLM_ENDPOINTS`.

8. **Publication.** This repository owns the ECR repository and a GitHub OIDC
   role that may only push to it, trusted for the `agent-core` repository and
   its default branch (not for pull requests). The `agent-core` CI builds the
   image, pushes it by immutable digest and records the digest in the run
   summary; this repository deploys only a digest it copied from there. The
   build passes `--build-arg GIT_SHA=<commit>`, which the image exposes as
   `AGENTCORE_GIT_SHA` (item 9). Neither the role nor the repository exists yet;
   see "Agent Core image publication" in `docs/gaps/OPEN_GAPS.md`.
9. **Identity of the running build.** `GET /version` returns
   `{package, contract, sha}`; like `/healthz` it is unauthenticated, outside
   `/v1` and exposes no data. `contract` is the schema version of the public
   contracts, `sha` is `AGENTCORE_GIT_SHA`. A smoke after each deploy should
   compare `sha` with the digest's commit.
10. **Key rotation without a restart.** The files read by `--identity-keys` and
    `--staff-keys` are re-read at most every `--keys-reload-seconds` (default 5;
    `0` disables it). A rotation is: publish the new `kid` next to the old one,
    wait for the interval, retire the old one. A broken file keeps the last good
    keys, so a half-written file does not take the service down.
11. **Export for ingestion.** With `--registry-api`, read-only routes under
    `/v1/export` (`runs`, `runs/{run_id}/events`, `registry-events`) feed the
    improvement engine's ingestion, paginated with `after` and `limit` (maximum
    500). They need a staff credential carrying the `exporter` role (or
    `admin`); the staff-key issuer is therefore asked to mint one for the
    ingestion service. The routes replace a read-only database role for this
    purpose.
12. **Schema changes are expand-only** ([agent-core ADR 0022](https://github.com/pulso-factored/agent-core/blob/main/docs/adr/0022-superficies-estables-y-migraciones-compatibles.md)).
    `agentcore migrate` runs before the new image starts and the previous image
    must keep working on the new schema, so a rollback is "redeploy the
    previous digest" with no schema undo. A removal ships one version after
    nothing deployed uses it. This repository still has to prove it on every
    bump: run the previous image against the new schema (see the gap "Agent
    Core schema compatibility smoke").

## Implementation status

Nothing for Agent Core is declared in Terraform and nothing is deployed.

- **Delivered in `agent-core` (pulso-factored/agent-core#19, merged):** `GET
  /healthz`, `GET /readyz` (PostgreSQL check, `503` naming the failed check) and
  `agentcore migrate`. `migrate` applies the existing idempotent schema scripts
  to the engine/registry database and, with `--eval-dsn`, to the evaluation
  database; it has no version table, so it suits a new or already-migrated
  database but cannot evolve a schema.
- **Delivered in `agent-core` (pulso-factored/agent-core#25, open when this was
  written):** a Dockerfile (non-root, no secrets in the image) and a CI job that
  builds it and checks both properties; `GET /version`; key-file reload;
  `/v1/export`; registry reads for aliases and versions; `release_settings`
  proposals; `eval_run_id` in `gate_failed`; the stability and expand-only
  rules of item 12.
- **Missing in `agent-core`:** the CI step that pushes the image and records its
  digest (blocked on item 8: no ECR repository or push role exists).
- **Contract mismatch to resolve before scheduling the sweep:** `agentcore
  sweep` reads `AGENTCORE_DATABASE_URL` (not `AGENTCORE_REGISTRY_DSN`) and
  needs `--registry <authoring directory>`, which a container built from the
  code would not carry.
- **Demo-only today:** outside demo mode `serve` requires real tools,
  authorization, transcript, calibration, classifier, field-classifier and
  grant-active pieces. None exist yet (they belong to other units), so a
  deployment can only run with `AGENTCORE_ALLOW_DEMO=1` and synthetic data.
  That is acceptable only for the hackathon `prod` demo; contract item 5 applies
  once the real pieces exist.

## Consequences

- AGENTS.md, CONTEXT.md and the README name Agent Core as a workload of this
  repository (journal 0010).
- The Agent Core Terraform slice needs the image digest, the contract items
  above and the egress design; the prerequisites are tracked in
  `docs/gaps/OPEN_GAPS.md`.
- Customer-facing use needs a decision on data residency and a bank-grade
  review; `us-east-1` and a hackathon-grade `prod` do not satisfy that.

## Open questions

- Single database instance with two logical databases, or two instances for
  the evaluation database.
- Hosting for the analytics view (Phoenix or CloudWatch only).
- Ingress for Agent Core: the improvement service's route is a private path
  through an identity-aware proxy and an internal ALB, with no API Gateway
  placeholder; whether Agent Core follows it, and who terminates TLS, is open.
