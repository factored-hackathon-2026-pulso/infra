# I06 — verified removal of legacy local preflight assets

## Exact targets and consumer check

The removed targets are `local/preflight.stack.json`,
`local/preflight.tools.json`, `scripts/doctor.py`, and
`tests/test_doctor.py`. Before removal, repository search found no infra CI or
Terraform consumer: only the doctor test itself and the I04 migration/README
references remained. Git history identifies them as the old U01 Windows local
preflight, not a Terraform deployment contract.

The current `improvement-engine` repository was inspected at its default
branch. It owns its Rust CI/integration contracts, but has **no confirmed engine
replacement** at the same `local/` or `scripts/doctor.py` paths. This removal
therefore does not claim a like-for-like migration.

## Decision

The files are removed for the Terraform-first, no-consumer scope of `infra`.
They were **not invoked by infra CI**, did not provision AWS and were explicitly
non-authoritative since I04. A future engine-local developer doctor belongs in
`improvement-engine` and must be designed/tested there; it must not return to
this Terraform repository.
