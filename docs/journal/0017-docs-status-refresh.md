# 0017 - Status docs refresh after infra#26

**Date:** 2026-10-03

## Change

Docs only. `README.md` no longer says every workload module is unwired: `engine_platform` and `bridge_services` are wired
into `staging` and `prod` behind switches that default off (listed in the new README sections). `deployment-status.md`
gains rows for both, and its Agent Core section reflects the `ecr` module and `bridge_services`. In `OPEN_GAPS.md` the
key-delivery row is reduced to the remaining item (images pre-create state directories owned by uid 10001) and new rows
cover the OIDC push role for the new ECR repository, `core-migrate`/sweep/alarms, unconfirmed secret and Cloud Map
names, missing CI `terraform test` coverage, the `core_data` test on Terraform 1.16.4 and the fact that nothing is applied.

## Not changed

Terraform code, workflows, ADRs and the data pipeline rows (owned by the data-pipeline team).
