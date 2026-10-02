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
| CI/CD | Credential-free fmt/validate and portable contracts run in CI | OIDC plan/apply, deploy and rollback remain manually approved future slices; no auto-deploy exists |

The repository deliberately does not own Compose, Podman, LocalStack, engine
fixtures or the engine integration suite. `improvement-engine` must provide
the local replacement before legacy infra-local assets are considered removed
without a capability gap.

## Integration contracts to preserve

### Runtime database access

Environment configuration must select one
`database_connection_secret_arn` per environment, which is either the
RDS-managed master secret or a separately approved application secret. The
runtime role may read only that secret through Secrets Manager/KMS; Terraform
does not write its value. The task receives the reference and the engine
validates the standard database JSON schema at startup without logging it.

An ECS/RDS declaration is not deployable application connectivity until the
selected secret, endpoint/environment binding, rotation behavior and a
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
