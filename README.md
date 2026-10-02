# Pulso infrastructure

Terraform and AWS deployment infrastructure for the autonomous improvement
service. This repository does not own the engine's local runtime or test
harness: `improvement-engine` owns Compose/Podman, fixtures, PostgreSQL,
LocalStack and integration CI.

## Terraform baseline

`terraform/envs/{staging,prod}` declares credential-free provider,
backend and deployment input contracts. `terraform/modules/` separates network,
data, identity/OIDC, compute and observability interfaces. This baseline creates
no AWS resources, remote state or credentials; those require a reviewed,
environment-specific Terraform slice and an approved plan.

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

## Legacy inventory

The existing `local/` profiles and `scripts/doctor.py` remain only as a
non-authoritative migration inventory. Do not extend or use them as a deployment
stack. See [I04 migration inventory](docs/migration/i04-legacy-local-assets.md).

See [agent instructions](AGENTS.md), [context](CONTEXT.md) and slice journals.
A green structural check is not evidence of an AWS deployment.
