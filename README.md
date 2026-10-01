# Pulso infrastructure

Infrastructure and local environment for the autonomous improvement service.

## Current slice

Windows-first agent guidance and partial read-only doctor contract. No working Podman/PG/S3 stack, Terraform deployment or cloud resources are claimed.

Run `python -m unittest discover -s tests -v` from this directory. Three tests cover missing/invalid configuration and explicit blocking of unimplemented checks. Run `python scripts/doctor.py --config path/to/config.json --json`; the partial doctor intentionally cannot certify readiness yet.

See [agent instructions](AGENTS.md), [context](CONTEXT.md) and [slice journal](docs/journal/0001-bootstrap.md). CI proposed in this branch runs the same tests on Windows/Linux without secrets; local green is not CI proof.
