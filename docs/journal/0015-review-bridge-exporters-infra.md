# 0015 - Independent review of the bridge exporters infra (a18b270, 5175295)

**Date:** 2026-10-03

## Method

Read the module, the shared `workload` / `workload_iam` changes, both env wirings, ADR 0009 and `docker-entrypoint.sh`
of `core-bridge` (read only). Mutation-tested the Terraform tests: 16 mutations of `bridge_services` and 4 of
`workload` (remove or widen a rule, cross-wire a secret, flip a default, open a CIDR, relax a validation).

## Findings

- Medium, fixed: the tests passed on 9 of 16 mutations because `container_settings` re-stated literals
  (`read_only_root_filesystem = true`) instead of reading the rendered task definition, and no test pinned the
  secret-variable to ARN wiring, rule ports, CIDRs, the S3 / gateway egress, the per-service database switches or the
  wildcard ARN validation. Now: `workload` exposes `container_definition`; `bridge_services` reads
  `container_settings`, `rendered_containers` and `rendered_secrets` from it; 8 runs added. All 16 + 4 mutations
  fail the tests (the `enabled` default flip is pinned by the Python contract test).
- Low, fixed: `tests/test_agent_core_aws_scale_contract.py` accepted the legacy unquoted `-chdir` form after PR #25;
  it now requires the quoted form and rejects the unquoted one. The pin SHA and log-group-owner edits in
  `test_release_manifest.py` were justified (pin 894fa65; the module really owns three new log groups).
- Least privilege, SGs, names: no finding. Each execution role gets only its own variables' ARNs, no wildcard, no
  task statements, no Core write; every rule is a security-group reference except VPC-CIDR 443; the foreign database
  ingress is off by default and each switch opens only its own group; no name collides with `engine_platform`.

## Open (not fixable in this repo)

- High for first deploy: the `core-bridge` Dockerfile creates `/run/pulso-keys` (0700, uid 10001) but not
  `/var/lib/pulso-exporter`. A Fargate ephemeral volume inherits ownership of the image path, so with no such directory
  the cursor volume is root-owned and the exporter (uid 10001) cannot create `state.sqlite`. The image needs
  `install -d -o 10001 /var/lib/pulso-exporter` (and the platform exporter image the same for its state path).
- Secret and Cloud Map names (`core/bridge-signers`, `core-runtime`) are not yet confirmed against the Agent Core
  slice (plan section 9 questions 4, 8, 9).
