# Pulso infrastructure

Terraform and AWS deployment infrastructure for the autonomous improvement
service. This repository does not own the engine's local runtime or test
harness: `improvement-engine` owns Compose/Podman, fixtures, PostgreSQL,
LocalStack and integration CI.

## Terraform baseline

`terraform/envs/{staging,prod}` declares credential-free provider, backend and
deployment input contracts. `terraform/modules/` provisions the shared AWS
foundation: VPC with public/private subnets and a versioned NAT choice, private
ECS/Fargate compute, RDS, S3 source/artifact buckets, Secrets Manager metadata,
IAM task roles, CloudWatch logs and an ECS health alarm. API Gateway is deferred
until an approved authenticated private integration exists. It never
uploads bank data or a secret value.

ECS resolves the configured runtime secret before a container starts. The
execution role therefore receives a narrowly scoped `GetSecretValue` grant for
that exact secret; an optional `kms:Decrypt` grant is created only when the
environment supplies a customer-managed KMS key, and then only through that
region's Secrets Manager service with the exact secret ARN encryption context.
The task role remains limited
to the source/artifact object paths it consumes at runtime.

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

CI validates every environment without `plan` or `apply`. A future manual plan
gate needs approved AWS account/OIDC/state inputs and must not reuse the
engine's local CI.

## Deferred boundaries

VPN topology, database engine, API integration and tracing provider are
deferred decisions. The foundation deliberately exposes only configuration
that controls a current AWS resource. Cost and availability
trade-offs—especially NAT strategy—must be selected per environment in a later
approved plan.

## Removed local harness

The obsolete infra-local doctor/profiles were removed because they had no CI or
Terraform consumer and contradict this repository's Terraform-first scope. This
does not claim an engine replacement; see [I06 removal evidence](docs/migration/i06-legacy-local-removal.md).

See [agent instructions](AGENTS.md), [context](CONTEXT.md) and slice journals.
A green structural check is not evidence of an AWS deployment.
