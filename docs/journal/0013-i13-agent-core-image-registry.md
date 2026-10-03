# I13 — Agent Core image registry module

**Date:** 2026-10-03

## Objective

Declare the ECR repository that either build option for the Agent Core image needs (ADR 0003, "Publication"),
and an optional OIDC publisher role, without applying anything. Stacked on I12 (pulso-factored/infra#18).

## Change

- `terraform/modules/image_registry`: `aws_ecr_repository` (immutable tags, scan on push, AES256 or the given
  KMS key), `aws_ecr_lifecycle_policy` (untagged expire; image-count cap), and a publisher role plus policy that
  exist only when an approved OIDC provider **and** exact subjects are given. Subjects follow the `ci_roles`
  rules (protected environments only, no wildcards, no branch, tag or pull request subject). The policy can
  log in and push to this repository only; it cannot delete images.
- `terraform/envs/{staging,prod}`: module `agent_core_image_registry`, gated by `agent_core_repository_name`
  (default empty: nothing is declared). Set it in one environment per AWS account.
- CI: init and `terraform test` of the module under the existing credential-free step.
- Docs: ADR 0003 "Publication", `deployment-status.md`.

## Decision

The publisher role is optional and depends on D-3 (who builds the image); the repository is needed either way.
Trust uses protected-environment subjects like `ci_roles`, not a branch subject as first proposed in I12.

## Verification

- RED first: `python -m unittest tests.test_agent_core_image_registry` ran 9 tests with 7 failures and 2 errors.
- GREEN: `python -m unittest discover -s tests` -> `Ran 102 tests ... OK`.
- `terraform fmt`, `init`, `validate` and `terraform test` were **not** run locally (Terraform is not installed on
  this host); CI runs them on the pull request and is the evidence.

## Not done

No ECR repository or role exists: no plan, no apply. No provider ARN, subjects or repository name were chosen.
No push step exists in `agent-core` CI. The lifecycle cap (100 images) must stay above the digests still
deployed; nothing checks that.
