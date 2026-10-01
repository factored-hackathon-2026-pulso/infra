# U01 slice 3 — Podman backend probe

Observable behavior: the `stack` profile checks whether the configured Podman client can reach its backend. It never treats an installed CLI as readiness, and it neither initializes nor starts a machine.

TDD evidence:

- Podman absent: RED `blocked/preflight_not_implemented`; GREEN `failed/podman_missing` through the CLI with an isolated `PATH`.
- Actual stack profile: a failed backend cannot report ready. On this Windows host the fixed `podman info --format json` command reports `podman_backend_unavailable`; no environment mutation occurred.
- Boundary regressions: a portable fake backend verifies `podman_backend_ready`, exact argv `info --format json`, and a bounded timeout whose process output is not copied into the report.

The implementation uses the absolute executable found in `PATH`, fixed argument vector, bounded subprocess, and discarded output. Optional `probe_timeout_seconds` is versioned and constrained to integer 1–30 seconds (default 5) for the stack profile too. `podman_backend_ready` only establishes that the backend is reachable; it does not certify Compose, PostgreSQL, LocalStack/S3, Core, data, IAM or deployment.

Run: `python -m unittest discover -s tests -v` and `python scripts/doctor.py --config local/preflight.stack.json --json` (expected exit 1 on the current host).

Windows local suite: 14/14 PASS. Independent adversarial review reproduced the former 12-test suite and found no blocker; its documentation findings and timeout/argv coverage were addressed after the review. CI still must validate this HEAD.

Pending: targeted nonzero/OS-error branch coverage, a real Podman machine authorized by the user, Compose services, and their integration checks.
