# I06 — modular AWS foundation

## Scope

Added Terraform interfaces and staging/prod wiring for VPC/subnets/NAT posture,
security boundaries, IAM policy boundaries, compute, storage, database, Secrets
Manager, API Gateway and observability. The modules are contracts only: no AWS
resource, credential, remote state, plan, apply, OIDC or deployment automation
is introduced.

## Deferred choices

VPN topology, compute engine, database engine and provider-specific API/tracing
integrations remain versioned inputs or deferred decisions. NAT strategy is an
explicit cost/availability input, not a hidden default.

## Legacy cleanup

The old local preflight assets were removed only after exact target/consumer
inventory; see [I06 removal](../migration/i06-legacy-local-removal.md). No
like-for-like replacement in the engine is claimed.
