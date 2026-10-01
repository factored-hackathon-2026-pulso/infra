# I04 — Terraform-first infrastructure reframe

## Scope

Reframed `infra` as the AWS/Terraform deployment repository. Added provider,
backend and module interface contracts for demo, staging and production; added
credential-free Terraform checks to repository CI; removed the executable
reusable PostgreSQL workflow that ran `improvement-engine` tests.

## Intentional limits

No Terraform apply, remote state, AWS credentials, cloud resources, secrets,
dataset or engine code were created or changed. Existing local/doctor files are
documented as non-authoritative inventory rather than deleted or expanded.

## Verification

The TDD RED test was `python -m unittest tests.test_terraform_first_baseline -v`, before Terraform roots/workflow/migration inventory existed. CI and every root require Terraform 1.10+ because the native S3 backend contract uses `use_lockfile`; CI pins 1.10.5. Real AWS 5.100.0 lockfiles are committed per environment. After the first remote Ubuntu run exposed a Windows-only `h1` checksum, `terraform providers lock -platform=windows_amd64 -platform=linux_amd64` regenerated each lock and a regression requires at least the two platform hashes. Local fmt/validate is rerun after this compatibility correction. This is not a cloud plan, apply or deployment; independent infra/security review remains required before commit.
