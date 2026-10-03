# I12 — Agent Core scale-out, phases 0 and 1 (Terraform)

**Date:** 2026-10-03

## Objective

Declare the Agent Core workload (ADR 0003) with the pieces that let it scale out, and record the design in ADR 0005.
Counterpart in `agent-core`: ADR 0023 (S3 blob store, outbox relay, connection pool, sweep contract).

## Change

- New modules: `agent_core_network`, `ecr`, `rds_proxy`, `agent_core_data`, `agent_core_ingress`,
  `agent_core_workload`, `agent_core_observability`; `database` gains an `identifier` output.
- `staging` and `prod` wire them (a separate RDS instance via the existing `database` module, the shared ECS
  cluster from `compute`). New variables default to a safe posture: `agent_core_desired_count = 0`,
  `agent_core_allow_demo = false`, no event consumers.
- `docs/adr/0005-agent-core-escalado-fase-0-1.md`; updated ADR 0003 status note, README, deployment status and open
  gaps (declared is not applied; new gaps for the evaluation database, event consumers and blob migration order).
- CI: `terraform test` for the five modules that carry guards.
- Python contract test `tests/test_agent_core_aws_scale_contract.py`; `test_agent_core_scope_contract.py` updated
  because the README and status no longer say "not declared".

## Verification

Terraform 1.10.5 (the CI version) was run from the `hashicorp/terraform:1.10.5` image; the host has no Terraform.

- `terraform fmt -check -recursive terraform` → clean.
- `terraform init -backend=false -lockfile=readonly` + `terraform validate` for `staging` and `prod` → valid
  (provider lock files unchanged).
- `terraform test` with mocked providers: `agent_core_network` 4/4, `ecr` 2/2, `rds_proxy` 3/3,
  `agent_core_data` 5/5, `agent_core_workload` 7/7.
- `python -m unittest discover -s tests` → `Ran 55 tests ... OK`.

Failures hit and fixed on the way (kept here because they teach the next slice):

- A conditional returning objects with different attributes does not type-check; per-role container extras live
  in a local keyed by role.
- Mocked `aws_iam_policy_document` returns non-JSON, which the mocked role rejects; the assume-role policies use
  `jsonencode`. The mock also needs valid ARN defaults for roles, secrets and task definitions.

## Not done

- No plan against an account, no apply, no image in ECR, no secret value, no ACM certificate.
- Mocked tests prove the declared guards, not that AWS accepts the resources (for example, WAF rule syntax, the SNS
  filter policy on a raw-delivery subscription, the RDS Proxy target registration order).
- No cost estimate.
- Open design points are listed in ADR 0005 ("Not covered") and `docs/gaps/OPEN_GAPS.md`.
