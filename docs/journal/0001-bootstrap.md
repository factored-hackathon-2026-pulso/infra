# S0/U01 slice 1 — guides and preflight contract

Scope: agent guides and three failure/blocking behaviors, not a functioning dependency stack. User confirmed GitHub Issues, canonical labels, single-context docs and docs sliced with code. Main receives only an authorized README seed; work is on feature branch.

Independent adversarial reviewer re-ran 3/3 tests GREEN and reviewed boundaries/CI/docs; no blocker for this partial bootstrap PR, not full U01. Current output is always JSON; --json is accepted for an explicit caller contract, not a separate output mode. CI uses runner Python for this dependency-free slice; pin interpreter before adding dependencies.

TDD evidence on Windows:

1. Missing configuration: RED exit 0 incorrectly accepted; GREEN reports config_missing and exits 1.
2. Malformed JSON: RED missing diagnostic; GREEN reports config_invalid without echoing contents.
3. Existing JSON: RED unknown without diagnostic; GREEN blocked/preflight_not_implemented with remediation. This regression prevents treating the partial implementation as a healthy stack.

Command: `python -m unittest discover -s tests -v`. CI executes the same contract tests on Windows and Linux with a SHA-pinned checkout and no secrets. Local green does not prove remote CI green.

Pending: versioned schema, real tool/linker checks, Podman backend and PG/S3 smoke; full doctor currently fails closed with blocked for other input. No Terraform/apply or model calls. Python 3.12 is installed alongside 3.13; upstream Core requires 3.12 at the pinned snapshot.
