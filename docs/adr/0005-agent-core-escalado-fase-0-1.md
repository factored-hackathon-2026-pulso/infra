# Agent Core scale-out pieces: image repository, data plane, proxy, sweep schedule, relay alarms

Status: **Accepted** (2026-10-03). It adds to [ADR 0003](0003-agent-core-workload.md) and changes none of its
decisions. Accepting it and merging the Terraform creates no resources: nothing is applied (ADR 0002 item 7).
Counterpart in `agent-core`: ADR 0023.

## Context

A review of the Agent Core subsystems found what stops it from scaling out (the service keeps no state in memory):

- every unit of work opens its own PostgreSQL connection, so connections grow with tasks;
- the registry's content-addressed blobs live in PostgreSQL;
- the transactional outbox had no consumer, so `handoff_created` never left the database;
- the sweep needed a schedule and the relay needed alarms.

ADR 0003 (L9 revision) fixes the Core topology: a private service with no load balancer, WAF or public ingress,
one role set per workload, `core/*` secrets, Cloud Map names, and the generic `workload` / `workload_iam` modules.
A first draft of this work contradicted it (an internal ALB with WAF, its own task definitions and roles, a
different secret layout). This ADR keeps only the pieces that do not touch that topology and plug into it.

## Decision

Declare these modules. None replaces a module of ADR 0003.

| Module | What it declares | How it plugs into ADR 0003 |
|---|---|---|
| `ecr` | Immutable-tag, scan-on-push repository with a lifecycle policy. **Wired** in `staging` and `prod` as `<env>/pulso-core` | The ECR repository named by the "Publication" path and by the `Agent Core image publication` gap |
| `core_data` | Registry blob bucket (versioned, private, deletes denied), SNS topic for outbound events, one SQS queue **plus DLQ** per consumer filtered by `event_type`, DLQ and age alarms. **Wired** in both environments; no consumers by default | Output `task_statements` is meant for `workload_iam.task_statements`; it contains only S3 and SNS actions, so the module's own validation (no `kms:`, `secretsmanager:`, `iam:`, `sts:`, wildcards) accepts it |
| `rds_proxy` | RDS Proxy (TLS required, SCRAM, application secret, master secret refused) in front of the Core instance | Not wired. Adds a proxy hop to flow F5: the Core security-group slice must open `core-*` -> `proxy` -> `core-db` instead of `core-*` -> `core-db` |
| `scheduled_task` | EventBridge Scheduler launching a task definition with `create_service = false` (the sweep) with a role limited to that task and to `iam:PassRole` for the listed roles | Takes `workload`'s task definition; ADR 0003 already assigns "EventBridge sweep and migrate tasks" to this repository |
| `core_alarms` | Metric filter and alarms for the relay (`failed=N`, no running task) | Reads the log group owned by `observability` (DR-86) and never creates one |

### Choices worth recording

1. **Standard SNS topic, not FIFO.** The outbound event contract guarantees at-least-once delivery and
   de-duplication by `event_id`, not global order.
2. **Blobs use SSE-S3 by default and the topic is unencrypted by default.** ADR 0003 forbids `kms:` actions in a
   task role, so a customer-managed key would need a key policy that names the Core task role. The events carry
   no PII (`agent-core` ADR 0008). Both are variables.
3. **The bucket denies `DeleteObject`/`DeleteObjectVersion` to everyone** except `blob_admin_principal_arns`
   (empty by default) and refuses plain HTTP. With blobs in S3 the foreign key to `reg_blobs` is dropped, so
   integrity rests on the hash (verified on each read) and on blobs never disappearing.
4. **The sweep is a scheduled one-shot** (`rate(5 minutes)`, retried twice). Overlap is safe: the turn lease makes
   a live turn win over the sweep.
5. **The relay runs as a service** built with `workload` (`desired_count` may exceed one for a warm standby: an
   advisory lock keeps one active publisher). `AGENTCORE_ALLOW_DEMO` stays forbidden by `workload`.

## Interface additions with `agent-core` (extends the ADR 0003 contract)

| Variable | Kind | Used by |
|---|---|---|
| `AGENTCORE_DB_POOL_MAX` | plain environment | every Core task; tasks × pools × this value must stay under the proxy limit |
| `AGENTCORE_BLOB_BUCKET`, `AGENTCORE_BLOB_PREFIX`, `AGENTCORE_BLOB_KMS_KEY_ARN` | plain environment | every Core task; `migrate` drops the `reg_blobs` foreign key when the bucket is set |
| `AGENTCORE_EVENTS_TOPIC_ARN` | plain environment | `relay` |

Commands: `agentcore relay` (service), `agentcore sweep --once` (scheduled; now reads `AGENTCORE_REGISTRY_DSN`,
which closes the DSN mismatch recorded in OPEN_GAPS), `agentcore blobs-backfill` (one-off after enabling the
bucket). The DSN secrets must point at the proxy endpoint once the proxy is wired.

## Consequences

- Two extra self-contained resources per environment (repository, data plane); everything else is a module with
  tests, waiting for the Core workload slice.
- Cost is not estimated here. Fixed items when wired: the RDS Proxy; the existing NAT and RDS are unchanged.

## Not covered

- The Core workload itself: service, security groups, database, secrets, Cloud Map, log groups (ADR 0003).
- Ingress: ADR 0003 keeps it private with no load balancer; an internal ALB with WAF remains the documented
  alternative reserved for `edge`.
- Redis for the rate limiter, SQS workers for registry evaluations, FIFO action queues and the chain-event feed
  (they need `agent-core` ADRs first; see its ADR 0023, "Fuera de alcance").
- Verified only with `terraform validate` and `terraform test` against mocked providers; no plan, no apply.
