# Agent Core on AWS: Phase 0 and 1 scale-out foundation

Status: **Accepted** (2026-10-03). Accepting the ADR and merging the Terraform creates no resources: nothing is
applied (ADR 0002 item 7 stands). Counterpart in `agent-core`: ADR 0023.

## Context

ADR 0003 accepted Agent Core as a workload and left its Terraform, ingress, queueing and storage open. A review of
the subsystems found what stops it from scaling horizontally (the service keeps no state in memory, so the limits
are elsewhere):

- every unit of work opens its own PostgreSQL connection, so connections grow with tasks;
- the registry's content-addressed blobs live in PostgreSQL;
- the transactional outbox has no consumer, so `handoff_created` never leaves the database;
- the scheduled sweep, the migration and the ingress had no deployable shape.

## Decision

Declare, per environment, an Agent Core workload built from small modules. All are opt-in at the Terraform level
(`agent_core_desired_count = 0` declares the service without tasks).

| Module | What it declares | Why |
|---|---|---|
| `ecr` | Immutable-tag, scan-on-push repository with a lifecycle policy | Deploy by digest only (ADR 0003 contract item 1) |
| `agent_core_network` | Security groups ALB → service → RDS Proxy → database | Nothing but the proxy reaches the database |
| `rds_proxy` | RDS Proxy (TLS required, SCRAM, application secret) in front of the Agent Core instance | Task count no longer bounds database connections |
| `database` (reused) | A **separate** RDS instance for Agent Core | ADR 0003 item 2: workloads do not share an instance |
| `agent_core_data` | Blob bucket (versioned, private, KMS-capable, deletes denied), SNS topic for outbound events, one SQS queue **plus DLQ** per consumer filtered by `event_type`, DLQ and age alarms | Replaces blobs-in-PostgreSQL and gives the outbox a transport |
| `agent_core_ingress` | **Internal** ALB, HTTPS only (TLS 1.3 policy), regional WAF (per-IP rate limit and AWS managed rule sets) | Answers the ADR 0003 ingress question; limits anonymous callers, which the engine does not |
| `agent_core_workload` | Secret entries, execution/task/scheduler roles, task definitions for `serve`, `relay`, `sweep` and `migrate`, the `serve` and `relay` ECS services, Application Auto Scaling (CPU and requests per target), EventBridge Scheduler for the sweep | One image, four roles, least privilege per role |
| `agent_core_observability` | 5xx, p95 latency, unhealthy hosts, CPU, relay-failing and relay-not-running alarms | Operational signals for the new pieces |

### Choices worth recording

1. **Ingress is internal.** There is no public listener and no HTTP listener. The load balancer's security group
   admits only the CIDRs in `agent_core_ingress_cidrs` (never `0.0.0.0/0`, enforced by a variable validation).
   Who those callers are (private path, identity-aware proxy) is still a decision of the security owners.
2. **The target group probes `/healthz`, not `/readyz`.** `/readyz` checks PostgreSQL; using it would make ECS
   replace every healthy task during a database outage.
3. **Standard SNS topic, not FIFO.** The outbound event contract guarantees at-least-once delivery and
   de-duplication by `event_id`, not global order.
4. **Per-role secrets.** `serve` gets the full ADR 0003 set; `migrate` the two DSNs; `sweep` and `relay` only the
   registry DSN. The task role cannot read Secrets Manager (ECS injects the values).
5. **The blob bucket denies `DeleteObject`/`DeleteObjectVersion` to everyone** except principals listed in
   `blob_admin_principal_arns` (empty by default). With the blobs in S3 the foreign key to `reg_blobs` is dropped,
   so integrity rests on the hash (verified on each read) and on blobs never disappearing.
6. **Demo mode is prod-only.** `agent_core_allow_demo` sets `AGENTCORE_ALLOW_DEMO=1`; a precondition refuses it
   outside `prod` (ADR 0003 item 5).
7. **The sweep is a scheduled one-shot task** (`rate(5 minutes)`, retried twice). Overlapping runs are safe: the
   turn lease makes a live turn win over the sweep.
8. **The relay is an always-on singleton by lock.** `relay_desired_count` may exceed one for a warm standby; an
   advisory lock in PostgreSQL keeps one active publisher.

## Interface additions with `agent-core` (extends the ADR 0003 contract)

| Variable | Source | Used by |
|---|---|---|
| `AGENTCORE_DB_POOL_MAX` | plain environment | all roles; per-task pool (tasks × pools × this value must stay under the proxy limit) |
| `AGENTCORE_BLOB_BUCKET`, `AGENTCORE_BLOB_PREFIX`, `AGENTCORE_BLOB_KMS_KEY_ARN` | plain environment | all roles; `migrate` drops the `reg_blobs` foreign key when the bucket is set |
| `AGENTCORE_EVENTS_TOPIC_ARN` | plain environment | `relay` |
| `AGENTCORE_REGISTRY_DSN` | secret | `sweep` now reads the same variable as `serve` and `migrate` (the ADR 0003 contract mismatch is closed) |

Commands: `agentcore relay` (service), `agentcore sweep --once` (scheduled), `agentcore migrate` (one-off),
`agentcore blobs-backfill` (one-off, after enabling the bucket).

The DSN secrets must point at the **RDS Proxy endpoint**, not the instance. The proxy endpoint is a Terraform
output of the proxy module; setting the secret value stays out of band.

## Consequences

- Staging and prod each gain nine modules' worth of resources; none is applied until the OIDC, state and
  authorization gaps are closed.
- The `compute` module's cluster is shared by the engine and Agent Core services.
- Cost is not estimated here. The notable fixed items are the RDS instance, the RDS Proxy, the ALB, the WAF and
  the NAT already required.

## Not covered (kept as open gaps)

- Destination control on egress (`controlled_nat` is still a generic 443 rule).
- The evaluation database (`AGENTCORE_EVAL_DSN`): the secret entry exists; the database is an operator-created
  logical database on the Agent Core instance until a decision (ADR 0003 open question 1) says otherwise.
- Redis for the rate limiter, SQS workers for registry evaluations, FIFO action queues and the chain-event feed
  (they need `agent-core` ADRs first; see its ADR 0023, "Fuera de alcance").
- `identity-keys` file delivery, and the real tools, authorization, transcript, calibration and classifier pieces
  that `serve` needs outside demo mode.
- Verified only with `terraform validate` and `terraform test` against mocked providers; no plan against an
  account, no apply.
