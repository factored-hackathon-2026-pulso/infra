# Pulso infrastructure

Infrastructure and local environment for the autonomous improvement service.

## Current slices

Windows-first agent guidance and partial read-only doctor contract remain in
place. No working local Podman/PG/S3 stack, Terraform deployment or cloud
resources are claimed.

Run `python -m unittest discover -s tests -v` from this directory. The
contract tests cover missing/invalid configuration, installed and missing
tools, explicit blocking of unimplemented stack checks, and the reusable
PostgreSQL CI boundary. Run `python scripts/doctor.py --config
path/to/config.json --json`; the partial doctor intentionally cannot certify
readiness yet.

Run `python scripts/doctor.py --config local/preflight.tools.json --json` for
read-only Git/Python probes. Success has scope `tools`, not stack readiness.
Optional `probe_timeout_seconds` accepts integers 1–30 (default 5); no custom
commands or arguments are allowed and process output is discarded.

Run `python scripts/doctor.py --config local/preflight.stack.json --json` to
see the pending stack gate (expected exit 1). Podman, PostgreSQL/S3
connectivity and Core compatibility are not implemented in this slice.

`postgres-integration.yml` is a reusable GitHub Actions workflow for the
improvement-engine's explicit, ignored PostgreSQL artifact-migration test. It
creates an isolated service database on GitHub-hosted Ubuntu runners; it does
not use repository/environment secrets or deploy anything. A caller invokes it
by SHA, for example:

```yaml
jobs:
  postgres-artifact-migration:
    uses: pulso-factored/infra/.github/workflows/postgres-integration.yml@<infra-commit-sha>
```

The workflow checks out the caller repository, so this must only be invoked by
a repository that has `improvement-engine-core`, its U02 migration test, and
Rust 1.98.1. Its fixed command cannot be supplied by the caller and preserves
the caller's lockfile with `--locked`. Do not reuse the CI-only URL outside the
ephemeral service database.

Before its first use, confirm in the `infra` repository Actions settings that
the private reusable workflow is accessible to `improvement-engine`; GitHub
controls this policy outside of this repository. The first caller CI run is the
only evidence that the cross-repository boundary and real PostgreSQL gate work.

See [agent instructions](AGENTS.md), [context](CONTEXT.md) and the slice
journals. CI runs the portable Python contract tests on Windows/Linux; remote
green is still distinct from local green. Configuration belongs in Git and
must not contain credentials.
