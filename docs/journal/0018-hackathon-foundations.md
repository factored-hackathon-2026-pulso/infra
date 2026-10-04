# 0018 hackathon foundations and free_plan profile (PR 32)

- Adds the single-environment hackathon stack (three hosts, free_plan profile, buildbox, deploy tooling), ADR 0007 and ADR 0008.
- Fixes main's red `tests/test_aws_plan_review.py::CurrentTree` (`data_pipeline` default `us-east-2`) through the exact-default region allowlist in `scripts/aws_plan_review.py`.
- Fix found on the first real apply: an `enabled=false` host is created running, attached and then stopped; `ignore_changes = [associate_public_ip_address]` stops a stopped host from being replaced (`tests/test_compute_inactive_host_contract.py`, `protection.tftest.hcl`).
- Validation: `python -m unittest discover -s tests`, `terraform test` per module, Pester `scripts/tests`.
- Open note for owners: `hackathon_data` is excluded from the no-secret-values scan (random RDS master password lands in state, `ignore_changes = [secret_string]`), and ADR 0007/0008 deviate from ADR 0003/0004/0005 for the short-lived hackathon account; neither was edited here.
- `terraform/bootstrap/oidc_ecr.tf` and `modules/ci_roles` are alternatives per account (one GitHub OIDC provider per account).
