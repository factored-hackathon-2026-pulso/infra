# AWS deployment status and integration boundary

**Status:** current design contract. Terraform declarations are not evidence of
an applied AWS environment.

## Status matrix

| Area | Terraform status | Deferred or external prerequisite |
|---|---|---|
| Network and security | VPC, public/private subnets, NAT posture, workload/database security groups are declared | Private corporate access/VPN topology is external and creates no route here |
| Identity | `identity` declares the legacy `task`/`execution` roles. Modules `workload_iam` (per-workload roles), `ci_roles` (OIDC plan/apply/deploy, `count = 0` until inputs exist), and `auxiliary_roles` (sandbox, worker launch, reader) are declared but not yet wired into `envs/*` (see "Identity module gap list") | Account-level OIDC provider, exact subjects, permissions boundary and deploy policy are approved inputs; the roles themselves are unwritten |
| Storage and secrets | KMS-encrypted/versioned source and artifact buckets plus a runtime-secret container are declared | Backend/bootstrap KMS/state and secret values are provided outside Terraform; data-retention policy remains a deployment input |
| Database and compute | Private RDS PostgreSQL and ECS/Fargate task/service are declared | Engine DB secret reference/injection, task readiness/health contract and deployment smoke are not implemented by the declaration alone |
| Debug ingress | No public API, ALB or proxy is declared | **`dependency_blocked`** until the engine listener and approved internal-ALB plus identity-proxy contract exist |
| Observability | One CloudWatch log group per workload (owned by the observability module; compute consumes its name, fixing the duplicate `/pulso/<env>/improvement-engine`, DR-86), CPU diagnostics, SNS topic and CPU alarms are declared | Engine metrics/traces and actionable queue/progress/error/ingest/budget alarms require the engine-to-infra metric contract |
| Agent Core workload | **Not declared.** [ADR 0003](../adr/0003-agent-core-workload.md) (provisional acceptance) fixes topology, separation, flow matrix and release contract | ECR repository, ECS service and task roles, separate database, secrets, migration task, scheduled sweep and egress design are future slices; `agent-core` now builds an image in its CI but publishes no digest; Agent Core can only run in demo mode today |
| LLM gateway workload | **Not declared.** [ADR 0004](../adr/0004-llm-gateway-workload.md) accepts the scope, a stateless private service and provider egress owned by this workload | Image digest and ECR, ECS service and task role, secret entries, internal ingress and the controlled-egress design are future slices; the `llm-gateway` repository has a Dockerfile and CI but publishes no digest |
| CI/CD | Credential-free fmt/validate, portable contracts and Terraform tests (mock providers) run in CI; `release/validate_manifest.py` validates a deploy manifest offline | OIDC plan/apply, deploy and rollback remain manually approved future slices; no auto-deploy exists. `release/` tests run under the existing `python -m unittest discover -s tests` step; the workflow itself does not yet run the root-level `*.tftest.hcl` files (`terraform/envs/*/log_groups.tftest.hcl`), which is a Codex-owned file change |

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

Agent Core is a second workload on this foundation ([ADR 0003](../adr/0003-agent-core-workload.md)).
The ADR holds the ownership split and the contract with the `agent-core` repository; this section only
states what is true now.

- Terraform declares nothing for it and nothing is deployed.
- `agent-core` provides `/healthz`, `/readyz`, `/version` and `agentcore migrate`, plus a Dockerfile and a CI job
  that builds it (pulso-factored/agent-core#25). No digest is published and no ECR repository exists yet, so
  there is still nothing to deploy; who builds the image (D-3) is to be reviewed with those facts.
- It needs the `controlled_nat` egress profile (LLM endpoints and JEV). That is the existing
  "Controlled external egress" gap, not a new decision.
- Outside demo mode it requires pieces owned by other units, so a deployment would run synthetic-data demo
  doubles only. Nothing in this document makes it a banking-grade or customer-data service.

## Identity module gap list (OIDC and deploy roles)

Verified by reading `terraform/modules/identity` (no apply). Earlier text claimed OIDC trust and separate
deploy roles; the module declares only the rows marked "declared".

| Capability | State | Needed to close | Blocked by |
|---|---|---|---|
| `task` role (source/artifact S3, runtime DB secret read) | declared | per-workload split (engine api/worker, Core runtime/exporter) | design only |
| `execution` role (ECR/logs managed policy, runtime secret read) | declared | one execution role per workload reading only its own secrets | design only |
| GitHub OIDC provider and `ci-plan` / `ci-apply` roles | declared in `ci_roles` (`count = 0`; apply/deploy subjects must be protected environments); provider itself external | roles with `count = 0` until `github_oidc_provider_arn` and `github_subjects` are approved; read-only plan role separate from apply | external OIDC ARN and exact subjects (OPEN_GAPS) |
| Deploy role (ECS `UpdateService`/`RunTask`, `iam:PassRole` limited to task/execution roles with `PassedToService=ecs-tasks.amazonaws.com`) | declared in `ci_roles` | policy bounded by resource ARNs and a permissions boundary | approved deploy policy and boundary |
| Worker `ecs:RunTask` on the `sandbox-lab` ARN plus limited `PassRole` | declared in `auxiliary_roles` (disabled, CLQ-43) | extend engine worker task role | CLQ-43 sandbox contract |
| `task-sandbox` role (GetObject session prefix, PutObject results prefix, explicit Deny on source bucket, secrets, `ecs:*`, `iam:*`) | declared in `auxiliary_roles` (disabled, CLQ-43) | new role | CLQ-43 |
| `observability-reader` (read-only on `/pulso/<env>/*`) | declared in `auxiliary_roles` | new role | none technical |
| Guard: no Core/exporter/sandbox policy may reference the RDS master secret | declared in `workload_iam` | generalise to all roles (T-07) | none |
| Remote state/bootstrap trust (state bucket, lock, KMS) | **absent** | external bootstrap contract | OPEN_GAPS state/bootstrap |

No OIDC role is created until the external inputs exist; Terraform declarations here are not proof of an
applied or authorised environment.

## LLM gateway workload

The LLM gateway is a third workload on this foundation ([ADR 0004](../adr/0004-llm-gateway-workload.md)). The
ADR holds the ownership split and the contract with the `llm-gateway` repository; this section only states what
is true now: nothing is declared in Terraform and nothing is deployed. Agent Core still carries its own gateway,
so the provider keys and egress of ADR 0003 stay in force until Agent Core consumes the service.
