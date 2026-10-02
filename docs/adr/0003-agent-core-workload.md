# Agent Core as a deployed workload

Status: **Proposed** (draft for review; nothing here is implemented or applied).

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
5. **Engines** (previously deferred, now chosen for the Agent Core workload):
   ECS on Fargate for compute and RDS for PostgreSQL 16 for data. This follows
   Agent Core's own stack decision (no queues, Redis or vector store). The
   improvement-engine workload keeps its engines deferred.
6. **Egress.** The private subnets need outbound HTTPS to the LLM endpoint and
   to JEV. `nat_strategy` must therefore be `single` or `per_az` for this
   workload; `none` is only valid if VPC endpoints plus a pinned egress proxy
   are introduced in a later slice.
7. **No automated apply.** Unchanged from ADR 0002. Plan/apply automation, OIDC
   write permission and remote state remain separate reviewed slices.

## Ownership split

| Owned by `agent-core` | Owned by this repository |
|---|---|
| Dockerfile and image build | VPC, subnets, NAT, security groups |
| `/healthz` and `/readyz` endpoints | ECR repository |
| Versioned migrations and an `agentcore migrate` command | ECS cluster, service, task definition (pinned to an image digest) |
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
   are unauthenticated and expose no data.
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

4. **Plain configuration.** `AGENTCORE_SERVE_AGENTS`, host, port and the OTel
   endpoint are ordinary task environment variables.
5. **Forbidden in deployed environments.** `AGENTCORE_ALLOW_DEMO` must be unset.
   The service must exit non-zero, naming each missing piece, rather than start
   with test doubles.
6. **Commands.** `agentcore migrate` (run as a one-off task before a service
   update) and `agentcore sweep --once` (run on a schedule).
7. **Egress hosts.** `api.typesafe.ai` and each host in `LLM_ENDPOINTS`.

## Consequences

- AGENTS.md, CONTEXT.md and the README currently say Agent Core is external.
  They must be updated in the same slice that accepts this ADR.
- Items 2 and 6 of the contract (`/healthz`, `/readyz`, `agentcore migrate`) do
  not exist in Agent Core yet. The infrastructure slice that depends on them is
  blocked until they land.
- The module contracts in `terraform/modules/` stay interface-only until a
  reviewed slice implements them; this ADR does not create resources.
- Customer-facing use needs a decision on data residency and a bank-grade
  review; `us-east-1` and a hackathon-grade `prod` do not satisfy that.

## Open questions

- Single database instance with two logical databases, or two instances for
  the evaluation database.
- Hosting for the analytics view (Phoenix or CloudWatch only).
- Public ingress: API Gateway or an ALB, and who terminates TLS.
