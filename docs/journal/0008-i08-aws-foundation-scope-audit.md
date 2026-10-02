# I08 — AWS foundation scope audit

## Decision

`infra` is the deployable AWS boundary for `improvement-engine`: Terraform
modules and environment roots for network, IAM/OIDC, ECS/Fargate, encrypted
storage, private PostgreSQL, secrets, CloudWatch logs, metrics and alarms.
It does not own or execute the engine's local runtime, fixtures, Compose,
Podman, LocalStack, PostgreSQL migration suite or cross-repository test
workflow.

The retired local-harness journals were removed rather than kept as active
guidance. Their minimal migration evidence remains in
`docs/migration/i04-legacy-local-assets.md` and
`docs/migration/i06-legacy-local-removal.md`; Git history remains the complete
historical record. `README.md`, `CONTEXT.md`, ADR 0002 and I07/I08 are the
current operational documents.

## What the foundation declares

Two environments only are supported: `staging` and `prod` (the hackathon demo).
The Terraform graph contains VPC/public-private subnets/NAT, explicit workload
and database security-group flows, GitHub OIDC and separated deploy/execution/
runtime roles, ECS/Fargate, KMS-enforced S3, private RDS PostgreSQL, Secrets
Manager, CloudWatch and SNS alarms. VPN/customer gateway and public API edge
remain explicitly deferred because their external topology/authentication
contracts are not approved.

## Verification and non-claims

The scope boundary is covered by the portable contract suite: it rejects an
engine-test reusable workflow and the retired local assets. Terraform 1.10.5
formatting and backend-free initialization/validation for `staging` and `prod`
pass locally and in manual CI run `36963510094` on Windows and Ubuntu. These
are static validation results only: no AWS credentials, plan, apply, image
publication or deployment happened.
