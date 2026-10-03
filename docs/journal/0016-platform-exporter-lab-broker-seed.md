# 0016 - platform-exporter gets its lab-broker key seed

**Date:** 2026-10-03

## Change

The platform exporter now mints a per-attempt service JWT (journal PL-0009 and `docker-entrypoint.sh` of the
platform-exporter, read only): observations and cursor use `aud=control-api` with `PULSO_EXPORTER_KEY_CONTROL_API_SEED`;
artifact uploads use `aud=lab-broker` with its own key from `PULSO_EXPORTER_KEY_LAB_BROKER_SEED`.

- `bridge_services`: the `platform-exporter/keys` secret now feeds two variables of the platform-exporter container
  only, `control_api_seed` and `lab_broker_seed` (JSON keys, `valueFrom` suffix `:<key>::`), the same layout as
  `core/exporter-keys` for core-exporter. The execution role is unchanged: the same two own secret ARNs, no wildcard.
- Plan doc: section 9 question 4 (secret layout) and the section 11 gap table updated.
- Tests (RED first: 2 of 18 runs failed before the module edit): the exact secret-variable set of the platform exporter
  and the rendered `valueFrom` of the new variable; the runtime container carries neither seed. The existing
  execution-role assertions (exact ARN sets and counts per service) stay green.
- Mutations proven to fail the tests: wrong JSON key for the new variable, variable removed, extra foreign ARN
  (`core/exporter-keys`) added to the platform-exporter execution role.

## Operator note

The `platform-exporter/keys` secret value must now carry both `control_api_seed` and `lab_broker_seed` (distinct
b64url 32-byte Ed25519 seeds); public halves go to the engine verifier keys. Values are never in this repo.
