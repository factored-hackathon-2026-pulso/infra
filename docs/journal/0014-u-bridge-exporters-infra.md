# I14 - Infra for the Core bridge runtime, Core exporter and platform exporter

**Date:** 2026-10-03

## Objective

Close our own infra gaps for the services we own (V3 section 31.11, PL-L5): the composed `pulso-core-runtime` image in
its runtime and exporter roles, and the platform exporter. The Agent Core team's infra stays theirs; nothing here
duplicates it.

## Change

- `modules/workload`: additive `read_only_root_filesystem` and `ephemeral_volumes` (task-scoped Fargate ephemeral
  storage, no host path, no EFS). Defaults render nothing, so existing task definitions do not change. Needed by ADR 0009
  of `core-bridge` (`/run/pulso-keys`).
- New `modules/bridge_services` (opt-in, `enabled = false` plans nothing): three services, own secret entries
  (`core/bridge-signers`, `core/exporter-keys`, `platform-exporter/db-readonly`, `platform-exporter/keys`; names only),
  Core secrets consumed by ARN, one role pair per service, security groups by reference (F1 both ends, F2, F3, one
  database group each), Cloud Map `core-runtime` in the shared namespace, LLM gateway egress.
- `envs/{staging,prod}/bridge_services*.tf` (+ env tests): wiring in own files, all switches off, platform-exporter ECR
  through the shared `ecr` module.
- Pin text 86a7674 / 789d6c8 -> 894fa65 in ADR 0003, the plan document and the release fixtures and their test.
- Test repairs found on the way: `test_the_ci_runs_the_new_module_tests` was red on `main` since PR #25 changed the
  quoting of `-chdir` (now accepts both forms); the single-log-group-owner test lists `bridge_services`.

## First RED

`python -m unittest tests.test_bridge_services_contract`: 1 failure, 8 errors (no module). `terraform test` in
`workload`: the new volume run failed (inputs missing). `terraform test` in `bridge_services`: "unknown provider"
before `main.tf` existed.

## Verification (Terraform 1.16.4 locally; CI pins 1.10.5, which was not downloaded)

See the commit messages and the final report for counts. `core_data` test
`task_statements_stay_inside_the_workload_iam_rules` fails on 1.16.4 and is pre-existing from PR #22; not touched.
CI does not run `terraform test` for `workload`, `workload_iam`, `engine_platform`, `core_vpc_endpoints`,
`bridge_services` or the env tests; `.github/workflows` is Codex-owned, so adding them is a request, not done here.

## Not done / decisions held

No apply, plan or AWS call. No OIDC push role for the new repository (`ci_roles` blocked on inputs), no `core-migrate`
or sweep (Core slice), no alarms for the new services, no image: `platform-exporter` has no Dockerfile and does not yet
materialise its key seed (name `PULSO_EXPORTER_KEY_CONTROL_API_SEED` is provisional). The image must create
`/run/pulso-keys` and the state directories owned by its app uid, because ephemeral volumes inherit image ownership.
Open questions for the Agent Core team are in section 9 of `docs/architecture/agent-core-overlap-and-engine-plan.md`.
