# Agent Core overlap, engine platform and the pulso-core-runtime delta

Status: working plan, reconciled against `origin/main` at `994cb62` (2026-10-03), which contains #19, #21, #22
and our #23. Nothing here is applied. Supersedes the earlier version written against `c8a962e` and PR #20.

Principle: one company platform. The Agent Core team's modules stay theirs; we never copy or edit them. Our
responsibility is (a) the improvement-engine platform and (b) how *our* composed runtime image
(`pulso-core-runtime`, built from `core-bridge/` in the improvement-engine repository) is deployed on top of the
shared foundation.

## 1. What changed since #23's base

| Change | Effect on this plan |
|---|---|
| #19 (`ecr`) | Merged. One module for every image repository. The engine and sandbox images reuse it (section 5). |
| #21 / ADR 0004 | JEV key, provider settings and provider egress belong to the LLM gateway workload. Our runtime already consumes the gateway only (section 4). |
| #20 (`agent_core_network`, `_workload`, `_ingress`, `_data`, `_observability`, own roles) | **Closed, replaced by #22.** None of those modules exists on `main`. |
| #22 / ADR 0005 | Adds `core_data`, `rds_proxy`, `scheduled_task`, `core_alarms` (plus `ecr`) *on top of* ADR 0003 and changes none of its decisions. Only `ecr` and `core_data` are wired. |

Consequences, verified in the tree: there is **no `agent_core_workload` module**. The Core workload slice (ECS
service, security groups, separate database, secrets, Cloud Map names, per-workload roles) is still unwritten and
ADR 0003 ("Implementation status") says so. ADR 0003 item 2 stands: Core is a private Cloud Map service, no ALB,
no WAF. ADR 0005 states the same, so the ALB tension recorded in the earlier version of this document is resolved
in ADR 0003's favour and no longer needs an answer.

## 2. What of ours is obsolete

The parked branch `claude/u-infra-core-stack-parked` (local only, never pushed; `core_database`, `core_secrets`,
`core_stack`, their env wiring and docs) is **superseded** and must stay unpushed:

| Parked piece | Status |
|---|---|
| `core_stack` (service, exporter, migrate, sweep, security groups, Cloud Map) | Superseded by the generic `workload` / `workload_iam` modules plus the pending Core workload slice (ADR 0003). |
| `core_secrets` | Superseded by the `core/*` secret layout of ADR 0003 and `secrets`. |
| `core_database` (shared instance, logical databases) | Superseded: ADR 0003 and #22 settle on a separate Core instance. Only the grant contract survives, as a documentation delta (section 6). |
| Scheduler role least privilege (`ecs:RunTask` on the cluster ARN, `iam:PassRole` with `PassedToService`) | `scheduled_task` (#22) already limits the role to the one task and the listed `PassRole` targets. Nothing left to carry over. |
| Open questions "separate versus shared database", "ALB or Cloud Map", "sweep default" | Closed by ADR 0003 / 0005, or owned by the Core workload slice. |

Still ours and merged: `engine_platform`, `core_vpc_endpoints`, `workload_iam.pass_role_arns`,
`network.private_route_table_ids` (#23).

## 3. Decision: no new Terraform module for the runtime (superseded by section 11)

Superseded: section 11 records why the `bridge_services` module now exists. The reasoning below stays for the record.

Evidence that the existing generic `workload` module can already run our image by variables only:

- `image` accepts any `repo@sha256:<64 hex>` reference; ours is one immutable digest.
- `command` overrides the container command. `core-bridge/docker-entrypoint.sh` takes the first argument
  (`runtime | exporter | migrate | agentcore`), so `command = ["runtime"]`, `["exporter"]` and `["migrate", ...]`
  select the role of the same image, exactly the "one digest serves all roles" rule of ADR 0003.
- `port` (8000), `environment`, `secrets` (`arn` or `arn:json-key::`) and `service_registry_arn` cover the
  configuration surface in section 4. `create_service = false` covers `migrate`.
- Its guards are compatible with the runtime: `AGENTCORE_ALLOW_DEMO` is forbidden by both sides (the runtime
  exits with code 2 if it is present), digest pinning is enforced, the RDS master secret is refused.

A thin `pulso_core_runtime` wrapper module would only re-declare these inputs, and the surrounding slice it would
plug into (security groups, database, Cloud Map, roles) does not exist yet. Writing it now would pre-empt the Core
workload slice and duplicate ADR 0003. **We implement nothing** for the runtime; section 4 is the specification of
the values to pass when that slice lands, and section 7 lists what the image itself must change first.

## 4. Delta spec: deploying `pulso-core-runtime` on the shared foundation

One image digest, repository `<env>/pulso-core` (the `ecr` instance already wired as `core_ecr`), three roles.

### 4.1 Runtime service (`command = ["runtime"]`, port 8000, Cloud Map `core-runtime.<env>.pulso.internal`)

| Name | Kind | Source / value |
|---|---|---|
| `PULSO_TENANT_ID` | plain | **required** (empty exits 2): tenant allow-list primary entry; also required by the exporter. `PULSO_ALLOWED_TENANTS` (comma list) is optional. |
| `PULSO_CONTROL_API_URL`, `PULSO_LAB_BROKER_URL` | plain | engine `control-api` private DNS (`engine_platform` output `control_api_dns_name`); lab-broker is a route group of control-api (plan 16.11). Both must be non-empty or the runtime exits 2. |
| `PULSO_BRIDGE_INSTANCE`, `PULSO_BRIDGE_MAX_INFLIGHT`, `PULSO_EVAL_PERMITS`, `PULSO_KEYS_RELOAD_SECONDS` | plain | per-task identity (must be unique per task) and limits. |
| `PULSO_EVAL_BUDGETS_JSON` (or `PULSO_EVAL_BUDGETS` file path) | plain | static budget map, no secrets; with neither set every `budget_ref` fails closed. |
| `AGENTCORE_LLM_GATEWAY_URL` | plain | LLM gateway private URL (ADR 0004). |
| `PULSO_LLM_MODE`, `PULSO_LLM_STAGE_POLICY_JSON` (or `PULSO_LLM_STAGE_POLICY` file path), `PULSO_LLM_POLICY_REQUIRED` | plain | `PULSO_LLM_MODE=disabled` is the explicit fixture/test opt-out (reported as a double in `/version`); otherwise gateway URL and token are required, and having none is a startup error. |
| `PULSO_CORE_SHA`, `PULSO_SHA`, `PULSO_IMAGE_DIGEST` | plain | informational; `PULSO_CORE_SHA` must equal the pinned agent-core sha `894fa65` or be unset (else exit 2). |
| `PULSO_CORE_EXPORT_ENABLED` | plain | leave unset: Core's HTTP `/v1/export/*` stays off (we ingest through the exporter). |
| `AGENTCORE_DB_POOL_MAX` | plain | pass-through (ADR 0005). Blob bucket and SNS topic variables stay unset. |
| `AGENTCORE_REGISTRY_DSN`, `AGENTCORE_EVAL_DSN` | secret | JSON keys of `core/db-app` (`arn:json-key::`). |
| `AGENTCORE_LLM_GATEWAY_TOKEN` | secret | `core/llm-gateway-token`; our consumer token of the gateway; URL and token together (or `PULSO_LLM_MODE=disabled`). |
| `CORE_IDENTITY_KEYS_JSON`, `CORE_STAFF_KEYS_JSON` | secret | public key sets, a non-empty JSON object each (`core/identity-keys`, `core/staff-keys`); written as `identity.json` / `staff.json`. |
| `PULSO_SERVICE_KEYS_JSON` | secret | `core/bridge-service-key`; shape `{"keys": {"<kid>": {"iss", "aud", "key": <b64url 32 bytes>}}}`, public verifiers of the `/internal/v1` service JWT audiences (engine callers); written as `service.json`. |
| `PULSO_BRIDGE_IDENTITY_SIGNER_JSON`, `PULSO_BRIDGE_STAFF_SIGNER_JSON`, `PULSO_BRIDGE_CALLBACK_SIGNER_JSON`, `PULSO_BRIDGE_EXECUTOR_SIGNER_JSON` | secret | `core/bridge-signers` (`arn:json-key::` per variable, or four secrets). Each value is `{"kid": "...", "key": "<b64url 32-byte Ed25519 seed>"}`; callback (to control-api) and executor (to lab-broker) **must differ** (runtime exits 2 otherwise). Files `bridge-{identity,staff,callback,executor}.json`. |

Key delivery is ADR 0009 of `core-bridge`, verified against `docker-entrypoint.sh`: for the selected entrypoint it
validates each variable (missing or malformed exits 2 with `pulso:runtime_config_invalid: <VAR>`, names only),
writes the file (0400, uid 10001) into `/run/pulso-keys` (`PULSO_KEYS_DIR`), exports the path variable, then
`unset`s every secret variable before `exec`. **Storage requirement:** the image creates `/run/pulso-keys` as 0700
uid 10001; with `readonlyRootFilesystem` the task must mount a writable tmpfs or ephemeral volume at that path
(otherwise the entrypoint exits 2, "cannot be materialised"). The task definition injects the variables through
`secrets` only, with no key-volume mounts. Rotation is by task replacement.

Forbidden and not needed: `AGENTCORE_ALLOW_DEMO`, `AGENTCORE_JEV_API_KEY`, `LLM_ENDPOINTS`, per-endpoint keys and
the `AGENTCORE_KEYS_*` names of ADR 0003 item 3: the composed runtime never reads them (no occurrence in
`core-bridge/src`). Once ADR 0004 is in force the runtime needs **no external egress**, only the gateway, so the
`controlled_nat` requirement of ADR 0003 item 5 does not apply to it; it still applies to the gateway.

### 4.2 Exporter service (`command = ["exporter"]`, no port, `desired_count` 1)

| Name | Kind | Source / value |
|---|---|---|
| `CORE_EXPORT_DATABASE_URL` | secret | `core/db-exporter` (role `core_exporter_ro`, read-only). This is the ingest path; Core's `/v1/export/*` stays off (`PULSO_CORE_EXPORT_ENABLED` unset), which also means the "Agent Core export credential" gap is not needed by us. |
| `EXPECTED_RUNTIME_DB`, `EXPECTED_EVAL_DB` | plain | logical database names the exporter must verify. |
| `PULSO_TENANT_ID`, `PULSO_CORE_INSTANCE`, `PULSO_EXPORTER_BINDING_REF` | plain | |
| `PULSO_INGEST_BASE_URL` | plain | engine `control-api` private DNS. |
| `PULSO_EXPORTER_KEY_CONTROL_API_SEED`, `PULSO_EXPORTER_KEY_LAB_BROKER_SEED` | secret (`core/exporter-keys`, one JSON key each) | b64url 32-byte Ed25519 seed as a raw string; the entrypoint writes `exporter-control-api.key` / `exporter-lab-broker.key` and exports the path variables `PULSO_EXPORTER_KEY_CONTROL_API` / `_LAB_BROKER` (optional plain `PULSO_EXPORTER_KEY_*_KID`). Two distinct audience keys; their public halves go in the engine's `verifier-keys` secret. Same `/run/pulso-keys` tmpfs requirement. |
| `PULSO_EXPORTER_STATE_DIR` | plain | writable directory for the cursor (SQLite). On Fargate it is ephemeral task storage: a restart replays from the anti-entropy rescan (`PULSO_EXPORTER_RESCAN_S`); a volume is a decision, not assumed. |
| `PULSO_EXPORTER_POLL_S`, `_RESCAN_S`, `_SWEEP_S` | plain | defaults 5, 900, 86400. |

### 4.3 Migrate (`command = ["migrate", ...]`, `create_service = false`)

No key variables (the `migrate` and `agentcore` entrypoints materialise nothing), so no tmpfs is needed.

Runs `agentcore migrate` with the migrate DSN (`core/db-migrate`). The runtime itself also applies the
`pulso_bridge` schema and its migrations at startup under an advisory lock, using `AGENTCORE_EVAL_DSN`
(question 1).

### 4.3.1 Secret grouping to env mapping

| Secret | Env var(s) injected |
|---|---|
| `core/bridge-signers` | `PULSO_BRIDGE_{IDENTITY,STAFF,CALLBACK,EXECUTOR}_SIGNER_JSON` (runtime) |
| `core/exporter-keys` | `PULSO_EXPORTER_KEY_CONTROL_API_SEED`, `PULSO_EXPORTER_KEY_LAB_BROKER_SEED` (exporter) |
| `core/bridge-service-key` | `PULSO_SERVICE_KEYS_JSON` (runtime) |
| `core/llm-gateway-token` | `AGENTCORE_LLM_GATEWAY_TOKEN` (runtime) |
| `core/identity-keys`, `core/staff-keys` | `CORE_IDENTITY_KEYS_JSON`, `CORE_STAFF_KEYS_JSON` (runtime) |
| `core/db-app`, `core/db-exporter` | `AGENTCORE_REGISTRY_DSN`, `AGENTCORE_EVAL_DSN`; `CORE_EXPORT_DATABASE_URL` |

### 4.4 Network (flow matrix of ADR 0003, our side)

F1 `engine-worker -> core-runtime:8000`; F2 `core-runtime -> control-api:8080` (callbacks and tool calls); F3
`core-exporter -> control-api:8080`; F5 Core tasks -> Core database (through `rds_proxy` if it is wired). The engine
inputs `core_runtime_security_group_ids` (F1 source side) and `core_callback_security_group_ids` (F2 and F3 source
side, so it must include the exporter's group as well as the runtime's) are already variables of `engine_platform`;
set them to the Core workload slice outputs when they exist.

## 5. Engine images: reuse `ecr`, nothing parallel

`envs/{staging,prod}/engine_platform.tf` now instantiates the shared `ecr` module once per image with
`for_each`: `<env>/pulso-engine` (control-api, worker, migrate) and `<env>/pulso-sandbox-lab`, gated by
`engine_ecr_enabled` (default `false`, a separate switch from `engine_platform_enabled` because the repositories
must exist before a digest can be pushed and the workloads need that digest). Output `engine_ecr_repository_urls`.
No new module, no `aws_ecr_repository` outside `modules/ecr`; a contract test pins both. Push permissions (OIDC)
remain the existing `ci_roles` gap.

## 6. Delta still held for the Agent Core team (documentation only)

- Grant contract for the separate Core database bootstrap: `REVOKE ALL ... FROM PUBLIC`, per-role `CONNECT`, and
  `ALTER DEFAULT PRIVILEGES FOR ROLE <owner>` for tables and sequences, so expand-only migrations (agent-core
  ADR 0022) do not silently remove access from the runtime and exporter roles. The role bootstrap is a human
  step (ADR 0003 item 2).
- Roles needed by our image on top of ADR 0003: `core_exporter_ro` must read the tables the exporter lists, and
  the runtime role must be allowed to create and own the `pulso_bridge` schema (or the migrate task must).

## 7. Image-side gaps (status)

1. **Closed in the image** (ADR 0009 of `core-bridge`): the entrypoint now materialises the four bridge signers, the
   identity/staff/service key sets and the two exporter seeds from the variables of section 4. No Terraform change
   is needed; the task definition injects them through `secrets`.
2. **Closed here, pending the Agent Core team's agreement:** ADR 0009 requires a writable path at `/run/pulso-keys`
   under a read-only root filesystem. Fargate has no tmpfs, so `workload` gained two additive inputs
   (`read_only_root_filesystem`, `ephemeral_volumes`; defaults render nothing, existing task definitions are unchanged)
   that mount task-scoped ephemeral storage. Files stay 0400 uid 10001 and the secrets are unset from the environment.
3. The runtime pins agent-core `894fa65` (ADR 0009 of the pin bump, on top of `789d6c8`; `PULSO_CORE_SHA` must equal it).
   ADR 0003 text and the release fixtures now cite it. The real `pin_manifest_digest` (`ed000b81...` per that ADR) is
   recorded by whoever creates `contracts/agent_core/pin.json`; the fixtures keep placeholder digests.

## 8. Engine platform (unchanged, #23)

control-api (also the `lab-broker` route group), worker, migrate and sandbox-lab are declared behind
`engine_platform_enabled` (default `false`); human-issuer (local-only) and console (`edge` blocked) are not
declared. Shared foundations are inputs; no VPC, NAT, ALB, WAF, cluster or database instance is created. Secrets
are names only. No Core DSN, provider key or JEV key reaches an engine workload (enforced by a test).
Provisional engine variable names (CLQ-39): `PULSO_DATABASE_DSN`, `PULSO_SERVICE_SIGNING_KEY`,
`PULSO_VERIFIER_KEYS`, `PULSO_CORE_BRIDGE_URL`, `PULSO_SANDBOX_TASK`.

Not done: OIDC deploy and plan roles (`ci_roles`, blocked on inputs), engine metric alarms (need the metric
contract), the release-manifest extension for engine digests, and the runbook update.

## 9. Questions for the Agent Core team (relayed by the user)

1. Who owns the bridge schema DDL (`pulso_bridge` in the eval database)? The runtime applies it at startup with
   `AGENTCORE_EVAL_DSN`; should that DSN's role be allowed to create it, or does the `migrate` task run it?
2. We added optional `read_only_root_filesystem` and `ephemeral_volumes` (default off, no diff for existing
   workloads) to the shared `workload` module for `/run/pulso-keys`. Is that acceptable to you, or do you prefer to own
   the change?
3. Resolved for our flows: `bridge_services` opens F1, F2 and F3 itself (both ends, by security-group reference).
   Still open: who opens the Core database security group for our runtime and exporter (F5)? Ours is opt-in
   (`manage_core_database_ingress`, default off) so it cannot duplicate yours.
4. Is this secret layout for the extra material acceptable: `core/bridge-signers` (4 seeds), `core/exporter-keys`
   (2 seeds), reuse of `core/bridge-service-key` for `PULSO_SERVICE_KEYS_JSON`, `core/llm-gateway-token`?
5. Should `core/jev` and `core/llm-endpoints` be dropped from the Core workload slice, given that the composed
   runtime consumes the gateway only (ADR 0004)?
6. Is a shared Cloud Map namespace `<env>.pulso.internal` acceptable, and who creates it? Our modules take its id
   as an input.
7. Closed: ADR 0003 and the release fixtures now cite pin `894fa65` (was `86a7674` / `789d6c8`). Still open: who records the real `pin_manifest_digest`.
8. `bridge_services` names its ECS services `pulso-core-runtime`, `pulso-core-exporter` and `pulso-platform-exporter`
   (log groups `/pulso/<env>/pulso-*`). Will the Core workload slice deploy its own `pulso-core-runtime` too, or is ours
   the single runtime? We must not both declare the same service, log group or Cloud Map name.
9. Secret value shapes we assume: `core/db-exporter` and `core/bridge-service-key`, `core/identity-keys`,
   `core/staff-keys`, `core/llm-gateway-token` are whole-secret strings; `core/db-app` has JSON keys `registry_dsn` and
   `eval_dsn`. Is that how you will create them?

## 10. Local verification

Terraform 1.16.4 locally (CI pins 1.10.5). Mock providers only; no plan or apply against an account.

## 11. Bridge services: gap analysis and what was added

Scope: only the services we own (`pulso-core-runtime` image in its runtime and exporter roles, and the platform
exporter; PL-L5 of V3 section 32.4 and section 31.11). Foundations (VPC, endpoints, cluster, namespace, ECR module,
KMS, database instances) are inputs. Nothing is applied.

| Need | Before | Now |
|---|---|---|
| Task definitions, digest pinning, no `AGENTCORE_ALLOW_DEMO`, master-secret guard | `workload` (generic) | reused unchanged |
| Read-only root plus writable `/run/pulso-keys` (ADR 0009), exporter cursor dir, `/tmp` | missing (no volume support) | `workload.read_only_root_filesystem` / `ephemeral_volumes` (additive, default no-op) |
| Secret layout `core/bridge-signers` (identity, staff, callback, executor), `core/exporter-keys` (control_api_seed, lab_broker_seed) | missing | entries created by `bridge_services` (names only, no versions) |
| `core/db-app`, `core/db-exporter`, `core/identity-keys`, `core/staff-keys`, `core/bridge-service-key`, `core/llm-gateway-token` | none (Core slice not merged) | consumed by ARN (`core_secret_arns`), never created here |
| Platform exporter read-only DB credential and key seed | missing | `platform-exporter/db-readonly` (whole connection string) and `platform-exporter/keys`; names only |
| Env and secret variable names per service (section 4.1, 4.2, platform exporter env) | spec only | rendered by `bridge_services`; tests pin the exact secret variable sets and the absence of demo, JEV, provider and static-token variables |
| IAM least privilege | `workload_iam` | one pair of roles per service, each execution role limited to its own secret ARNs, task roles without statements |
| SG: runtime/exporters to control-api (F2, F3), engine to runtime (F1) | engine side only, via inputs | both ends opened by `bridge_services` (references only); `check` refuses overlapping engine inputs |
| SG: Core DB (F5) and platform DB read | missing | egress from each service to exactly one database group; the ingress on that group is opt-in |
| Cloud Map `core-runtime.<env>.pulso.internal` | namespace and control-api only | `core-runtime` service in the shared namespace (never creates one) |
| LLM gateway reach (ADR 0004) | missing | egress to the gateway security group; gateway side admits our `core-runtime` group |
| ECR | `core_ecr` (`<env>/pulso-core`) and engine repos | platform-exporter repository through the shared `ecr` module (`bridge_ecr_enabled`) |
| OIDC push role for the new repository, `core-migrate`, sweep, alarms for the new services | blocked / Core slice | not done (see journal 0014) |

Wiring lives in `envs/{staging,prod}/bridge_services*.tf` (all switches default off). Provisional names to confirm
with the platform-exporter code: `PLATFORM_DB_URL` (existing) and `PULSO_EXPORTER_KEY_CONTROL_API_SEED` (provisional,
aligned with ADR 0009; the platform exporter does not materialise keys yet).
