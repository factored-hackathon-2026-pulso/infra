# Pulso infrastructure

Infrastructure and local environment for the autonomous improvement service.

## Current slice

Windows-first agent guidance and partial read-only doctor contract. No working Podman/PG/S3 stack, Terraform deployment or cloud resources are claimed.

Run `python -m unittest discover -s tests -v` from this directory. Twelve tests cover strict versioned configuration, installed/missing tools, a reachable/unreachable Podman boundary and explicit failure of an unusable stack.

Run `python scripts/doctor.py --config local/preflight.tools.json --json` for read-only Git/Python probes. Success has scope `tools`, not stack readiness. Optional `probe_timeout_seconds` accepts integers 1–30 (default 5); no custom commands or arguments are allowed and process output is discarded. Configuration belongs in Git and must not contain credentials.

Run `python scripts/doctor.py --config local/preflight.stack.json --json` to validate the Podman backend. It runs only the fixed `podman info --format json` probe, discards its output and never initializes or starts a Podman machine. `probe_timeout_seconds` is optional, versioned and bounded to 1–30 seconds for both profiles. A working backend is not yet a working product stack: PostgreSQL/S3 connectivity and Core compatibility remain pending.

See [agent instructions](AGENTS.md), [context](CONTEXT.md) and [slice journal](docs/journal/0003-podman-backend-probe.md). CI runs the same tests on Windows/Linux without secrets; local green is not CI proof.
