# I07 — deployable shared AWS Terraform foundation

## Scope

I07 turns I06 contracts into AWS resources for `staging` and `prod` only;
`prod` is the hackathon demo. The graph covers VPC, two-AZ public/private
subnets, NAT routes, runtime/database security groups, ECS Fargate, RDS, S3,
Secrets Manager metadata, IAM roles, CloudWatch logs and an ECS CPU alarm. It
never uploads source data or a secret value. API Gateway is deliberately
deferred: this slice has no approved authenticated private integration.

No Podman, Compose, LocalStack, doctor, fixtures or engine test workflow is
added: those remain exclusively in `improvement-engine`.

## TDD and validation

`tests/test_deployable_aws_foundation.py` was RED against I06 because modules
were interface-only and roots accepted resource IDs. It is GREEN after modules
create resources and roots compose module outputs. `python -m unittest discover
-s tests -v` passed 20 tests on Windows. CI also runs credential-free Terraform
tests for both execution-role secret-policy branches: empty KMS input and an
exactly scoped customer-managed key. They use a mocked AWS provider and do not
contact AWS APIs, create a cloud plan, apply, or deploy resources; each test
does execute Terraform's local plan-mode evaluation against the mock.

Terraform is absent from this host, so local `fmt`/`validate` is unverified.
The pinned CI performs credential-free fmt/init/validate for staging then prod.
That proves formatting plus Terraform configuration and provider-schema
validation, but not an authenticated AWS plan, API reachability, apply, or
deployment until CI and an authorized manual plan are observed.

The runtime group owns no inline `ingress`/`egress` arguments; all rules are
standalone resources. On a new VPC security-group creation, the AWS provider
removes AWS's default allow-all egress and the two explicit rules then become
the desired egress surface. A deployed predecessor that tracked an inline
HTTPS rule cannot be upgraded by mixing either `egress {}` or `egress = []`
with standalone rules: the provider treats that as conflicting ownership.
This repository has no deployed I07 state. If a future deployed state needs
that transition, use an approved, separately reviewed staged state-migration
runbook (including backup and an explicit maintenance window); do not apply
this module as an implicit one-step migration.

## External requirements

Manual plan/apply needs an approved AWS account/region, unique bucket names,
reachable immutable image, CIDRs/AZ/NAT decision, RDS retention/deletion
settings, alarm target, state bucket/locking and GitHub OIDC trust. Those are
versioned environment inputs outside Git; no default account or public ingress
is assumed.

## Security and configuration correction

The ECS task-definition `secrets` reference is resolved by the execution role,
before the task role is active. The exact runtime secret is therefore granted
to a dedicated execution-role policy; `kms:Decrypt` is added only for the
explicit optional customer-managed key input, constrained to the region's
Secrets Manager `kms:ViaService` and the exact secret encryption context. The
task role keeps only S3 runtime-data permissions. Root and module inputs that did not control a
resource (`compute_engine`, caller resource IDs, ingress placeholders and
unwired alarm/trace settings) were removed rather than retained as deceptive
configuration. The source bucket now shares the artifact bucket's incomplete
multipart-upload retention guard.
