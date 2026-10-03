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
   ordinary task environment variables. The identity public-key file read by
   `--identity-keys` holds public keys only and is delivered as configuration.
5. **Forbidden in deployed environments.** `AGENTCORE_ALLOW_DEMO` must be unset.
   The service must exit non-zero, naming each missing piece, rather than start
   with test doubles. See "Implementation status" for why this cannot hold yet.
6. **Commands.** `agentcore migrate` (run as a one-off task before a service
   update) and `agentcore sweep --once` (run on a schedule).
7. **Egress hosts.** `api.typesafe.ai` and each host in `LLM_ENDPOINTS`.

   **Pending change ([ADR 0004](0004-llm-gateway-workload.md)):** when Agent Core consumes the `llm-gateway`
   service, `LLM_ENDPOINTS`, the per-endpoint keys (item 3) and the provider hosts (this item) move to the gateway
   workload, and Agent Core gets the gateway URL and its own consumer token instead. Until then this contract
   stands as written.

## Implementation status

Nothing for Agent Core is declared in Terraform and nothing is deployed.

- **Delivered in `agent-core` (pulso-factored/agent-core#19, merged):** `GET
  /healthz`, `GET /readyz` (PostgreSQL check, `503` naming the failed check) and
  `agentcore migrate`. `migrate` applies the existing idempotent schema scripts
  to the engine/registry database and, with `--eval-dsn`, to the evaluation
  database; it has no version table, so it suits a new or already-migrated
  database but cannot evolve a schema.
- **Missing in `agent-core`:** a Dockerfile and an image CI that publishes a
  digest.
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
