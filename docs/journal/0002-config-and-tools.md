# U01 slice 2 — schema and actual tool probes

Observable scope: strict versioned configuration and read-only Git/Python probes, not stack readiness. An array root, unsupported schema, boolean revision, arbitrary command, empty/duplicate/unknown checks reject before execution and never echo configuration. tools profile reports its limited scope; stack remains explicitly blocked pending PG/S3 and backend checks.

TDD Windows evidence:

- Root object rejection: RED preflight_not_implemented instead of config_invalid, GREEN after validation.
- Python available: RED exit 1, GREEN actual subprocess --version.
- Invalid schema: RED seven unsupported values accepted as blocked, GREEN strict validator.
- Missing Git: RED config_invalid, GREEN git_missing with empty PATH and actual process invocation.
- Git+Python positive regression: actual installed tools, not recordings.

Fixed allowlist, no shell/custom arguments; probe stdout/stderr discarded. Probe timeout is configurable in versioned JSON: optional integer probe_timeout_seconds in 1–30, default five seconds. Deadline acceptance test: RED config_invalid, GREEN actual Python probe; invalid deadlines covered by rejection regression. No version compatibility claim: Python probe is host interpreter, not verification of Core's Python 3.12 requirements.

Run tests: python -m unittest discover -s tests -v.
Run tools: python scripts/doctor.py --config local/preflight.tools.json --json.
Run stack: python scripts/doctor.py --config local/preflight.stack.json --json (expected exit 1, blocked).

Windows local suite: 9/9 PASS. Independent adversarial reviewer reproduced tests, tools success and stack blocking, and found no blocker for this partial slice. Schema-remediation clarity improved from review. CI for this revision pending; previous bootstrap CI cannot certify these changes. Failure-code branches for timeout/nonzero/OS errors still need targeted external-boundary coverage before full U01 closure. No deployment/model calls; environment restrictions do not prove Windows incompatibility.
