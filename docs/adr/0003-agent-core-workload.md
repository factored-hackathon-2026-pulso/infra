# Agent Core as a deployed workload

Status: **Accepted** (provisional: decisions D-3 and D-6 of the two-team plan; the acceptance record belongs to
the human owners and this revision does not replace it). Accepting the ADR creates no resources: see
"Implementation status". Revised for package L9 (plan 17.3.9, DR-88..DR-91, DR-94, CLQ-38/39).

## Context

ADR 0001 and ADR 0002 scope this repository to the improvement engine and treat Agent Core as an external
product. Agent Core has a bootable HTTP server (`agentcore serve`) and needs a place to run in `staging` and
`prod`. Rebuilding network, database and secrets plumbing in a second repository would split ownership of one
AWS account. The first revision of this ADR was written before several facts in the pinned Agent Core
checkout (contracts 1.3.0, SHA `86a7674`) were verified; the "Corrections" table lists each one.
The current pin is `894fa65` (ADR 0009 of the `core-bridge` pin bump, previously `789d6c8`; `PULSO_CORE_SHA` must equal it); `86a7674` below is the
SHA at which the corrections were verified.

## Decision

1. **Scope.** This repository owns the Terraform/AWS infrastructure that *runs* Agent Core and the offline
   release tooling (`release/`: deploy-manifest schema and validator). It does not own Agent Core's code,
   schema or runtime behaviour. The Core image is built by the Pulso side (D-3, provisional, to be reviewed
   with the agent-core team) from a pinned agent-core checkout; that build is outside this repository.
2. **Separation (private service, roles, secrets).** The engine and Core are two ECS/Fargate workloads on one
   shared network/observability foundation, and share nothing that carries authority:
   - *Service:* `pulso-core-runtime` is a private service (no public IP, no load balancer, no WAF, no public
     ingress). Name resolution is by Cloud Map private DNS (for example `core-runtime.<env>.pulso.internal`)
     and reachability by security group only. An internal ALB is the documented alternative and is reserved
     for a future `edge`; Service Connect is rejected (sidecar, opaque security-group semantics).
   - *Roles:* one task role and one execution role per workload. Each execution role reads only its own
     secrets (`kms:Decrypt` constrained by `ViaService` and `EncryptionContext:SecretARN`) plus ECR pull and
     logs. Core tasks get no AWS permissions beyond that, and no workload role may read the RDS master secret.
   - *Secrets:* separate Secrets Manager entries per workload (names and encryption only; values never in
     Terraform state or Git, never `aws_secretsmanager_secret_version`). Core: `core/db-app`
     (`{registry_dsn, eval_dsn}`), `core/db-migrate`, `core/db-exporter`, `core/keys`, `core/jev`,
     `core/llm-endpoints` plus `core/llm-key-<alias>`, `core/identity-keys`, `core/staff-keys`,
     `core/bridge-service-key`. Engine: `engine/runtime`, `engine/db-app`, `engine/service-key`. The engine
     never receives a Core DSN and Core never receives an engine DSN (CLQ-39 asks Codex to confirm the engine
     env names per profile).
   - *Data:* a separate RDS PostgreSQL 16 instance for Core (fixed `engine_version`, own parameter group,
     encrypted, backups). One instance with two logical databases (`core_runtime`, `core_eval`) and roles
     `core_owner`, `core_app`, `core_eval_app`, `core_exporter_ro` is the default; `core_eval_separate_instance`
     reserves two instances. Evaluation-load contention is measured in L10. Creating databases, roles and
     grants is not Terraform: it is an authorised human bootstrap step (L2 entrypoint) using the RDS master
     secret outside any runtime role.
3. **Environments and region.** Unchanged: `staging` and `prod` only; `us-east-1`, provisional (data
   residency of the decision-model provider is unanswered), `prod` is the hackathon demo.
4. **Engines.** ECS on Fargate and RDS for PostgreSQL.
5. **Egress.** Only `pulso-core-runtime` needs HTTPS egress to `api.typesafe.ai` and the `LLM_ENDPOINTS`
   hosts, so it needs `controlled_nat`. An open 443 rule is not proof that only those hosts are reachable;
   destination control stays `dependency_blocked` (see OPEN_GAPS "Controlled external egress").
6. **No automated apply.** Unchanged from ADR 0002. Plan/apply, OIDC write permission and remote state remain
   separate reviewed slices.
7. **Static refusals.** Image references must match `@sha256:<64 hex>` (tags are never deployed);
   `AGENTCORE_ALLOW_DEMO` is forbidden in a workload's environment or secrets and verified statically; task
   definitions never use a public IP.
8. **Release by joint manifest.** A release is described by `deploy-manifest.json` (schema
   `release/deploy-manifest.schema.json`, validator `release/validate_manifest.py`, rules M-01..M-10). It
   holds the digest pair, `contracts_version` / `pin_manifest_digest`, `schema_digest.{runtime,eval}`,
   `compat`, `assets`, `exporter`, `console`, `sandbox`, `approvals[]`, `smoke` and `rollback`. Incompatible
   manifests are rejected (`pulso:manifest_incompatible`). `signature` stays `dependency_blocked`: the
   manifest is pinned by its digest recorded in the approval and is never described as signed.
9. **Schema compatibility instead of migration versions (DR-88).** `agentcore migrate` is idempotent
   `CREATE ... IF NOT EXISTS` with no version table and no down direction, so migration heads cannot be
   compared. The manifest carries `schema_digest` (SHA-256 of the two schema files at the Core SHA). A changed
   digest needs a declared `compat` (`expand` with evidence that image N-1 runs against schema N, or
   `contract` with an explicit strategy). "Expand/contract tested in both directions" cannot be met for Core;
   only image N-1 against schema N is testable.
10. **Deploy order** (Pulso never updates before Core is ready): validate manifest and plan offline; human
    `terraform apply` only if there is a diff; manual RDS snapshots; `core-migrate` with the new image;
    schema smoke with the read-only role; update `pulso-core-runtime` and wait for `/readyz`; engine
    migration; update exporter then engine services; idempotent seed and smoke; deployment receipt.
11. **Rollback.** Restore the digest pair as a unit; data is not reverted. A rollback is a new plan with the
    previous manifest, never a manual service edit (the ECS circuit breaker reverts the task definition while
    Terraform state still points at the new one). PITR or snapshot restore is a separate human decision.
12. **Key files (DR-89).** Fargate injects secrets as environment variables, not files. The Core entrypoint
    materialises the identity/staff public-key files in tmpfs from those variables.

## Ownership split

| Owned by `agent-core` | Owned by `improvement-engine` | Owned by this repository (`infra`) |
|---|---|---|
| Source, schema scripts, `agentcore migrate`, `sweep`, `/healthz`, `/readyz`, configuration validation | Engine image and entrypoints (CLQ-38), engine migrations, `/internal/v1/*` API, observation ingest | VPC, subnets, NAT/endpoints, one security group per workload |
| Demo-mode guard and fail-closed startup | Engine env names per profile (CLQ-39) | ECR, ECS cluster, task definitions pinned to digests, services |
| Contracts and pin manifest | Sandbox image (CLQ-43) | RDS instances, KMS keys, Secrets Manager entries (names only) |
| | | Task/execution/CI roles, GitHub OIDC trust (blocked on inputs) |
| | | Log groups (one owner per workload), alarms, EventBridge sweep and migrate tasks |
| | | `release/` manifest schema and validator, deploy runbook |

The Core image (Dockerfile, wheelhouse, entrypoints `runtime`, `exporter`, `migrate`, `sweep`, `seed`) is built
on the Pulso side from the pinned checkout (D-3); the pinned `agent-core` tree has no Dockerfile.

## Flow matrix (security groups)

| Flow | Source -> destination:port |
|---|---|
| F1 invoke/read/alias/dry-run/version | `engine-worker` -> `core-runtime`:8000 |
| F2 callbacks (binding, broker, authorizations, evaluation) | `core-runtime` -> `engine-api`:8080 |
| F3 observations | `core-exporter` -> `engine-api`:8080 |
| F4 engine database | `engine-api`, `engine-worker`, `engine-migrate` -> `engine-db`:5432 (Core cannot reach it) |
| F5 Core database | `core-runtime`, `core-exporter`, `core-migrate`, `core-sweep` -> `core-db`:5432 (the engine cannot reach it) |
| F6 model egress | `core-runtime` -> NAT -> 443 (destination control blocked) |
| F7 AWS APIs | all -> VPC endpoints or NAT |
| F8 launch sandbox | `engine-worker` -> ECS API (IAM, not network) |
| F9 sandbox | `sandbox-lab` -> endpoints only |
| F10 user/console ingress | none (`edge` is `dependency_blocked`) |

## Interface contract

Both repositories must change this table in the same pair of pull requests.

1. **Image.** One immutable Core digest serves runtime, exporter, migrate, sweep and seed; tag
   `<sha_core7>-<sha_pulso7>`. Only digests are deployed.
2. **Network.** One port (default `8000`); `/healthz` liveness, `/readyz` readiness (checks PostgreSQL), both
   unauthenticated, outside `/v1`, exposing no data.
3. **Secrets.** Injected as environment variables by name: `AGENTCORE_REGISTRY_DSN`, `AGENTCORE_EVAL_DSN`
   (per JSON key of `core/db-app`), `AGENTCORE_KEYS_FINGERPRINT`, `AGENTCORE_KEYS_TOKEN_MAP`,
   `AGENTCORE_JEV_API_KEY`, `LLM_ENDPOINTS` (alias map, variable names only) and one variable per LLM endpoint.
4. **Plain configuration.** `AGENTCORE_SERVE_AGENTS`, host, port and `OTEL_*` variables; identity public keys
   are public material delivered as configuration.
5. **Forbidden.** `AGENTCORE_ALLOW_DEMO` must be unset in deployed environments and the service must exit
   non-zero naming each missing piece. This cannot hold yet (see below).
6. **Commands.** `agentcore migrate --eval-dsn ...` as a one-off task before a service update;
   `agentcore sweep --once` on a schedule.
7. **Egress hosts.** `api.typesafe.ai` and each host in `LLM_ENDPOINTS`.

   **Pending change ([ADR 0004](0004-llm-gateway-workload.md)):** when Agent Core consumes the `llm-gateway`
   service, `LLM_ENDPOINTS`, the per-endpoint keys and `AGENTCORE_JEV_API_KEY` (item 3) and the provider and JEV
   hosts (this item) move to the gateway workload, and Agent Core gets the gateway URL and its own consumer
   token instead. Until then this contract stands as written.

## Corrections to the first revision (DR-94)

| Earlier statement | Correct state at SHA `86a7674` / this revision |
|---|---|
| Core owns the Dockerfile and image CI | No Dockerfile in the pin; the image is built Pulso-side (D-3, provisional) |
| `/healthz`, `/readyz`, `agentcore migrate` missing in places | They exist (`api/app.py`, `cli.py`, `composition/migrate.py`) |
| Versioned migrations / migration heads | None: idempotent scripts; `schema_digest` and `compat` replace heads (DR-88) |
| Six secret variables | Full per-workload inventory above; two key files via entrypoint |
| One service | Runtime, exporter, one-off migrate, scheduled sweep |
| ALB/WAF owned for Core | Private service via Cloud Map and security groups; no ALB, no WAF |
| Open: one vs two databases | Default one instance with two logical databases; variable reserves two |
| Open: ingress | No ingress; Core -> engine flow F2 added |
| Egress vocabulary | `controlled_nat` only for `core-runtime`; control stays blocked |
| Sweep env mismatch (`AGENTCORE_DATABASE_URL`, `--registry`) | Resolved by the Pulso-side entrypoint; verify in L2 |

## Delivered by `agent-core` since that revision (pulso-factored/agent-core#25, open when written)

The "Corrections" table above is true for SHA `86a7674`. The pull request adds, in `agent-core`:

- A Dockerfile (non-root user, no secrets in the image) and a CI job that builds it and checks both properties.
  This is new input for D-3 (who builds the image); see "Open questions".
- `GET /version` returns `{package, contract, sha}`; like `/healthz` it is unauthenticated, outside `/v1` and
  exposes no data. `sha` is the build argument `GIT_SHA`, exposed as `AGENTCORE_GIT_SHA`.
- Key rotation without a restart: the files read by `--identity-keys` and `--staff-keys` are re-read at most
  every `--keys-reload-seconds` (default 5; `0` disables it). Publish the new `kid` next to the old one, wait
  for the interval, retire the old one. A broken file keeps the last good keys.
- Read-only routes `/v1/export/runs`, `/v1/export/runs/{run_id}/events` and `/v1/export/registry-events`
  (with `--registry-api`), paginated with `after` and `limit`, which need a staff credential carrying the
  `exporter` role (or `admin`). They are an application-level alternative to the read-only database role
  `core_exporter_ro` for ingestion; which one the exporter workload uses is a decision of this repository
  and the improvement-engine owners.
- Registry reads for aliases and versions, `release_settings` proposals and `eval_run_id` in `gate_failed`.
- Schema changes are expand-only ([agent-core ADR 0022](https://github.com/pulso-factored/agent-core/blob/main/docs/adr/0022-superficies-estables-y-migraciones-compatibles.md)):
  the previous image keeps working on the new schema, so a rollback is "redeploy the previous digest". This
  repository still has to prove it on every bump (gap "Agent Core schema compatibility smoke").

**Publication.** Whoever builds the image needs an ECR repository, which this repository owns. If D-3 moves
the build to `agent-core`, its CI would push by digest through a GitHub OIDC role limited to push on that one
repository and trusted only for the `agent-core` default branch (never pull requests); this repository would
deploy only a digest copied from that run. If D-3 stays Pulso-side, the same repository is pushed from the
Pulso release job and no `agent-core` role exists. Either way the repository itself is declared once and
nothing is applied (gap "Agent Core image publication").

## Implementation status

Terraform for Agent Core workloads is not merged yet; nothing is deployed and no plan was ever run. L9 delivers
modules and tests under mock providers only, plus `release/` (schema, validator, tests). Inherited
`dependency_blocked` items (OIDC, state/bootstrap, DB role creation, controlled egress, edge/console, human
IdP, manifest signing, functional alarms) stay blocked with their owners in `docs/gaps/OPEN_GAPS.md`.

Outside demo mode `serve` requires real tools, authorization, transcript, calibration, classifier,
field-classifier and grant pieces that do not exist, so a deployment can run only with
`AGENTCORE_ALLOW_DEMO=1` and synthetic data, acceptable only for the hackathon `prod` demo. This is a
dependency, not something Terraform resolves.

## Consequences

- AGENTS.md, CONTEXT.md and the README name Agent Core as a workload of this repository.
- Customer-facing use needs a data-residency decision and a bank-grade review; `us-east-1` and a
  hackathon-grade `prod` do not satisfy that.

## Open questions

- Whether `pulso-core-runtime` later sits behind an internal ALB (with `edge`) and who terminates TLS.
- Hosting for the analytics view (Phoenix or CloudWatch only).
- Confirmation of D-3 (who builds the image) with the agent-core team, now that `agent-core` ships a Dockerfile
  and an image build job (see "Delivered by `agent-core`" and **Publication.**).
