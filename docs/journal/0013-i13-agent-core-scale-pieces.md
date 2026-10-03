# I13 — Agent Core scale-out pieces (Terraform)

**Date:** 2026-10-03

## Objective

Add the scale-out pieces found by the Agent Core subsystem review without contradicting ADR 0003 (L9 revision).
Counterpart in `agent-core`: ADR 0023.

## History

A first version of this slice (PR pulso-factored/infra#20, branch `feat/agent-core-aws-fase0-1`) declared an
internal ALB with WAF, its own task definitions, roles and secrets. While it was open, `main` received the L9
revision of ADR 0003, which fixes a private service (no load balancer or WAF), the generic `workload` /
`workload_iam` modules and `core/*` secrets. The two designs conflicted, so the slice was redone on `main`
keeping only what does not touch that topology.

## Change

- New modules: `ecr`, `rds_proxy`, `core_data`, `scheduled_task`, `core_alarms`, each with `terraform test`.
- `staging` and `prod` wire only `core_ecr` and `core_data` (new required variable `core_blob_bucket_name`,
  optional `core_event_consumers`, default none). The two `log_groups.tftest.hcl` files gain the new variable.
- `docs/adr/0005-agent-core-escalado-fase-0-1.md`; README, deployment status and open gaps record what is
  declared and what waits for the Core workload slice.
- CI runs `terraform test` for the five modules; `tests/test_agent_core_aws_scale_contract.py` pins the guards
  and that this slice adds no load balancer, WAF, task definition or ECS service.

## Verification

Terraform 1.10.5 from the `hashicorp/terraform:1.10.5` image (the host has no Terraform). Results are in the PR
description. `python -m unittest discover -s tests` → `Ran 105 tests ... OK`.

## Not done

No plan, no apply, no image, no secret value. Mocked tests prove the declared guards, not that AWS accepts the
resources. `rds_proxy`, `scheduled_task` and `core_alarms` are not wired anywhere: they wait for the Core
workload slice (service, security groups, database, secrets, Cloud Map). No cost estimate.
