# AWS plan review checklist (offline)

Run against the Terraform tree before any real plan. No credentials; the provider plugin must be cached.

```
python -m unittest tests.test_aws_plan_review -v
python scripts/aws_plan_review.py              # grep-based items, exit 1 on FAIL
python scripts/aws_plan_review.py --validate   # plus init -backend=false and validate for staging and prod
terraform fmt -check -recursive terraform
```

`tests/fixtures/account_assuming/` is a deliberately bad tree; the test proves the checker fails on it.
FAIL blocks; GAP is reported and must have an owner.

| # | Item | Machine-checked rule | Manual follow-up |
|---|---|---|---|
| 1 | Module list matches ADRs 0002-0006; nothing duplicates agent-core shared infra | no | compare `terraform/modules/*` with the ADRs |
| 2 | Env variables carry no account assumptions | `account-default` (no default on region, KMS, bucket names) | review new variables |
| 3 | No hard-coded account ids or ARNs | `hardcoded-account-id` (placeholder `000000000000` and regex validations allowed) | |
| 4 | No hard-coded regions in .tf | `hardcoded-region` | |
| 5 | No public exposure by default | `public-db` (public IP, publicly_accessible), `open-ingress` (0.0.0.0/0 or ::/0 ingress) | confirm egress 443 scope |
| 6 | Bridge, engine and endpoint switches default off; data pipeline switch exists and is off | `switch-default-on`, `switch-not-off`, `switch-missing` | |
| 7 | State backend is a placeholder | `backend-not-placeholder`, `backend-example-missing-placeholder` | |
| 8 | Tags ManagedBy, Environment, Service on env roots | `tag-missing`, `module-no-tags` | |
| 9 | Least-privilege roles | `admin-policy` (AdministratorAccess, Action "*") | read IAM diffs; any `Resource = "*"` needs a justification |
| 10 | Validate and fmt clean | `--validate`, fmt | `terraform test` (mocked providers) |
| 11 | Secrets by name only, no values | no | no secret value may appear in a plan |
| 12 | Real plan (post-TA3) | no | 0 unexpected destroys; saved plan sha recorded |

## Gaps found on the current tree (2026-10-04, other lanes' modules not changed)

- G1: `data_lake` module exists but neither env root has a `data_pipeline_enabled` switch (ADR 0006); no way to keep it off or on.
- G2: both `backend.hcl.example` files pin `us-east-1` (placeholder only; harmless).
- G3: local Terraform is 1.16.4 while CI pins 1.10.5 and `required_version >= 1.10.0`; re-run `--validate` on 1.10.5 in CI.
- G4: `terraform validate` and `terraform test` pass on staging and prod; the provider was already cached (no network was used).
- Note: module-level `*_enabled` toggles in `bridge_services` default true; they are gated by the env switches, so not flagged.
