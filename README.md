# Pulso infrastructure

Infrastructure and local environment for the autonomous improvement service.

## Current slice

Windows-first agent guidance and partial read-only doctor contract. No working Podman/PG/S3 stack, Terraform deployment or cloud resources are claimed.

Run `python -m unittest discover -s tests -v` from this directory. Nine tests cover strict versioned configuration, installed/missing tools and explicit blocking of unimplemented stack checks.

Run `python scripts/doctor.py --config local/preflight.tools.json --json` for read-only Git/Python probes. Success has scope `tools`, not stack readiness. Optional `probe_timeout_seconds` accepts integers 1–30 (default 5); no custom commands or arguments are allowed and process output is discarded. Configuration belongs in Git and must not contain credentials.

Run `python scripts/doctor.py --config local/preflight.stack.json --json` to see the pending stack gate (expected exit 1). Podman, PostgreSQL/S3 connectivity and Core compatibility are not implemented in this slice.

See [agent instructions](AGENTS.md), [context](CONTEXT.md) and [slice journal](docs/journal/0002-config-and-tools.md). CI runs the same tests on Windows/Linux without secrets; local green is not CI proof.
