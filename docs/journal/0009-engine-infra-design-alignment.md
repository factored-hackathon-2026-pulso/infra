# Engine/infra deployment-boundary alignment

**Date:** 2026-10-02

## Objective

Make the AWS Terraform boundary truthful about what is declared, deferred and
dependent on the engine without adding infrastructure resources.

## Decision

The target local stack remains engine-owned; its absence is a tracked engine
gap rather than a reason for infra to retain a harness. ECS/RDS declarations
need an explicit runtime database-secret contract before they are considered
operable. Debug ingress is blocked on the selected internal-ALB plus
identity-proxy contract. CPU alarms remain diagnostics until the engine metric
and actionable-alarm contract exists.

## Evidence and follow-up

See `docs/architecture/deployment-status.md`, ADR 0002 and
`docs/gaps/OPEN_GAPS.md`. No apply, AWS credential, plan, secret value,
Terraform resource or deployment workflow was added by this documentation
slice.
