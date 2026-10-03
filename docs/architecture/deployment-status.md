# AWS deployment status and integration boundary

**Status:** current design contract. Terraform declarations are not evidence of
an applied AWS environment.

## Status matrix

| Area | Terraform status | Deferred or external prerequisite |
|---|---|---|
| Network and security | VPC, public/private subnets, NAT posture, workload/database security groups are declared | Private corporate access/VPN topology is external and creates no route here |
| Identity | GitHub OIDC trust and separate deploy/execution/runtime roles are declared | Account-level OIDC provider, exact subjects, permissions boundary and deploy policy are approved inputs |
| Storage and secrets | KMS-encrypted/versioned source and artifact buckets plus a runtime-secret container are declared | Backend/bootstrap KMS/state and secret values are provided outside Terraform; data-retention policy remains a deployment input |
| Database and compute | Private RDS PostgreSQL and ECS/Fargate task/service are declared | Engine DB secret reference/injection, task readiness/health contract and deployment smoke are not implemented by the declaration alone |
| Debug ingress | No public API, ALB or proxy is declared | **`dependency_blocked`** until the engine listener and approved internal-ALB plus identity-proxy contract exist |
| Observability | CloudWatch task log group, CPU diagnostics, SNS topic and CPU alarms are declared | Engine metrics/traces and actionable queue/progress/error/ingest/budget alarms require the engine-to-infra metric contract |
| Agent Core workload | ECR, a separate RDS instance with RDS Proxy, ECS services (API, outbox relay), task definitions (including the migration and the scheduled sweep), S3 blob bucket, SNS topic with SQS queues and DLQs, internal ALB with WAF, secret entries and alarms are declared ([ADR 0003](../adr/0003-agent-core-workload.md), [ADR 0005](../adr/0005-agent-core-escalado-fase-0-1.md)); validated with `terraform validate` and mocked `terraform test` only | Nothing is applied. Needs a published image digest, secret values, an ACM certificate, approved ingress CIDRs, the evaluation database, destination-controlled egress and the OIDC/state gaps; Agent Core can only run in demo mode today |
| LLM gateway workload | **Not declared.** [ADR 0004](../adr/0004-llm-gateway-workload.md) accepts the scope, a stateless private service and provider egress owned by this workload | Image digest and ECR, ECS service and task role, secret entries, internal ingress and the controlled-egress design are future slices; the `llm-gateway` repository has a Dockerfile and CI but publishes no digest |
| CI/CD | Credential-free fmt/validate and portable contracts run in CI | OIDC plan/apply, deploy and rollback remain manually approved future slices; no auto-deploy exists |

The repository deliberately does not own Compose, Podman, LocalStack, engine
fixtures or the engine integration suite. `improvement-engine` must provide
the local replacement before legacy infra-local assets are considered removed
without a capability gap.

## Integration contracts to preserve

### Runtime database access

Environment configuration must select one externally bootstrapped
`pulso_runtime` application-secret ARN per environment. It is distinct from
the RDS-managed master secret; Terraform blocks any attempt to bind the two
values. The runtime role may read only the application secret through
Secrets Manager/KMS; Terraform does not write its value. The task receives
the endpoint and application-secret reference, and the engine validates the
standard database JSON schema at startup without logging it.

An ECS/RDS declaration is not deployable application connectivity until the
application secret, endpoint/environment binding, rotation behavior and a
non-sensitive connection smoke test have been verified.

### Runtime egress

An environment chooses `aws_private_endpoints_only` or `controlled_nat`. The
first permits only approved AWS private endpoints. The second is allowed only
for an approved external dependency and needs a destination-control/logging
design. A generic TCP/443 egress rule is foundation plumbing, not proof that
only AWS APIs or a model provider are reachable.

### Internal debug ingress

The selected future route is `private access path -> identity-aware proxy ->
internal ALB -> engine task`. It requires an engine listener/health/auth
contract, proxy role mapping and an integration test before this repository
adds an ingress resource. There is no API Gateway placeholder and no direct
public task access.

## Agent Core workload

Agent Core is a second workload on this foundation ([ADR 0003](../adr/0003-agent-core-workload.md)); the scale-out
design is [ADR 0005](../adr/0005-agent-core-escalado-fase-0-1.md). The ADRs hold the ownership split and the
contract with the `agent-core` repository; this section only states what is true now.

- Terraform **declares** the workload (nine modules wired into `staging` and `prod`), but **nothing is applied**
  and nothing is deployed. `agent_core_desired_count = 0` is the default.
- The checks that exist are `terraform fmt`, `terraform validate` per environment and `terraform test` with
  mocked providers (network, ECR, RDS Proxy, data plane, workload). They prove the declared guards (no `0.0.0.0/0`
  ingress, digest-only images, per-role secrets, demo mode prod-only, master secret refused), not that AWS accepts
  the plan.
- `agent-core` provides `/healthz`, `/readyz`, `agentcore migrate`, `agentcore sweep --once` (same DSN variable as
  `serve`), `agentcore relay`, `agentcore blobs-backfill` and the Dockerfile, but there is still no image CI
  publishing a digest to ECR.
- It needs the `controlled_nat` egress profile (LLM endpoints and JEV). That is the existing
  "Controlled external egress" gap, not a new decision.
- Outside demo mode it requires pieces owned by other units, so a deployment would run synthetic-data demo
  doubles only. Nothing in this document makes it a banking-grade or customer-data service.

## LLM gateway workload

The LLM gateway is a third workload on this foundation ([ADR 0004](../adr/0004-llm-gateway-workload.md)). The
ADR holds the ownership split and the contract with the `llm-gateway` repository; this section only states what
is true now: nothing is declared in Terraform and nothing is deployed. Agent Core still carries its own gateway,
so the provider keys and egress of ADR 0003 stay in force until Agent Core consumes the service.
