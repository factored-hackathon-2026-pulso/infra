# Pulso infrastructure

Terraform and AWS deployment infrastructure for the autonomous improvement
service. This repository does not own the engine's local runtime or test
harness: `improvement-engine` owns Compose/Podman, fixtures, PostgreSQL,
LocalStack and integration CI.

## Terraform baseline

`terraform/envs/{staging,prod}` compose concrete Terraform modules for VPC,
public/private subnets and NAT, security groups, GitHub OIDC roles, ECS/Fargate,
S3, RDS PostgreSQL, Secrets Manager, HTTP API Gateway, CloudWatch and SNS.
Terraform has not been applied: a checked-in resource declaration is a deploy
plan, not evidence that AWS resources, remote state or credentials exist.

`staging` is the validation environment. `prod` is the demo environment for
the hackathon; it is not a banking production deployment. Staging validates
before a separately authorized production-demo change. There is deliberately no
plan, apply or deployment workflow yet: CI only formats and validates both
roots without credentials or a remote backend.

Copy an environment's `backend.hcl.example` outside Git and supply it only via
approved deployment configuration. State, plan files, credentials, data and PII
are ignored. `terraform init -backend=false` is used by CI solely to validate
the module graph without remote-state access.

Run:

```powershell
python -m unittest discover -s tests -v
terraform fmt -check -recursive terraform
```

CI validates every environment without `apply`. It has no reusable engine-test
workflow and does not invoke `improvement-engine`.

## Explicit operational boundaries

The OIDC issuer is fixed to GitHub Actions, but its thumbprint and allowed
subjects are environment inputs: this repository never guesses a GitHub
repository/branch trust rule. A VPN/customer gateway is intentionally not
created: the input data necessary to establish a private attachment has not
been approved. API Gateway is provisioned as an auditable entry layer but no
route integration is invented before the engine exposes its deployment target.
Tracing instrumentation is owned by the engine/platform; CloudWatch log groups
and alarms are the AWS sink and alert substrate. See `docs/gaps/OPEN_GAPS.md`
and `docs/runbooks/` before an apply.

## Removed local harness

The obsolete infra-local doctor/profiles were removed because they had no CI or
Terraform consumer and contradict this repository's Terraform-first scope. This
does not claim an engine replacement; see [I06 removal evidence](docs/migration/i06-legacy-local-removal.md).

See [agent instructions](AGENTS.md), [context](CONTEXT.md) and slice journals.
A green structural check is not evidence of an AWS deployment.
