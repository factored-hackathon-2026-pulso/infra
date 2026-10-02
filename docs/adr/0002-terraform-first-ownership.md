# Terraform-first deployment ownership

## Decision

`pulso-factored/infra` owns only Terraform/AWS deployment infrastructure for
the improvement engine. Its stable boundaries are environment roots, a remote
state configuration contract, AWS provider configuration, and modules for
network, data, identity/OIDC, compute and observability.

`pulso-factored/improvement-engine` owns its local dependencies and test
execution. This repository must not host Compose, fixtures, LocalStack,
PostgreSQL migration tests, or a reusable GitHub workflow that executes another
repository's engine tests. Existing local doctor files are a non-authoritative
migration inventory, not a supported deployment interface.

## Consequences

Terraform validation is credential-free and backend-free in pull requests.
Plans use approved OIDC credentials and environment backend configuration in a
future deployment slice; applies remain approval-gated and are out of scope.
The baseline has interfaces but intentionally creates no cloud resources,
state, secrets or data.

Old local profiles and doctor files are inventory while their engine-local
replacement is verified. They are not a supported interface and must not grow.
The previous reusable PostgreSQL engine test workflow is removed, eliminating
foreign SHA and cross-repository Actions permission coupling.

## Environment posture

Only `staging` and `prod` Terraform roots are supported. `prod` is the
hackathon demo environment, while `staging` validates its configuration first.
This repository intentionally has no deployment workflow, AWS credentials,
OIDC write permission, plan or apply automation. Adding any of those is a
separate reviewed decision with explicit authorization.

## AWS foundation status

The foundation declares VPC public/private subnet and NAT posture, security-group
and IAM-policy boundaries, ECS/Fargate, private RDS PostgreSQL, storage, Secrets
Manager, and the initial CloudWatch/SNS resource-health substrate through
environment inputs and module contracts. These are Terraform declarations, not
evidence that resources have been applied. Runtime database-secret injection, engine health
semantics, engine metrics/traces and actionable service alarms remain dependent
integration contracts; they are not implied by resource declarations. A public
HTTP API is specifically deferred: an
HTTP API v2 cannot be guarded by a security group, and an API with no approved
authorizer or private-ingress integration would be an unauthenticated public
surface. VPN topology, concrete compute/database engine and provider-specific
edge/trace integrations remain explicitly deferred rather than silently chosen.

The obsolete local doctor/preflight harness is not part of the target infra
boundary. Its removal is only complete once `improvement-engine` has a linked,
verified local replacement; this is a scope cleanup, not a claim that the
engine already has an identical local interface.

There is no deployable API module or public ingress in the current foundation.
Any future internal edge requires an approved listener, health/auth contract,
identity-aware proxy and integration tests before Terraform resources are added.
