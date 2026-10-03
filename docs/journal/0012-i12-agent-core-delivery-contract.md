# I12 — Agent Core delivery contract

**Date:** 2026-10-03

## Objective

Record in this repository what `agent-core` delivered for the requests this repository raised
(pulso-factored/agent-core#25) and what each side still owes. Documentation and structural tests only; no
Terraform, workflow, secret or AWS change.

## Change

- `docs/adr/0003-agent-core-workload.md`: interface contract items 8 to 12 (publication through an ECR
  repository and an OIDC push role, `GET /version` and `AGENTCORE_GIT_SHA`, key rotation without a restart,
  the `/v1/export` routes and the `exporter` role, expand-only schema changes); the implementation status now
  lists what `agent-core` delivered and what is still missing (the push-by-digest step).
- `docs/architecture/deployment-status.md`: the Agent Core row and section no longer say there is no
  Dockerfile or image CI.
- `docs/gaps/OPEN_GAPS.md`: the workload-declaration row is updated and three gaps are added: image
  publication, export credential, schema compatibility smoke.

## Decision taken here (review it)

Question: where does `agent-core` publish its image? Answer recorded in ADR 0003 item 8: this repository
provisions the ECR repository and a GitHub OIDC role that can only push to it, trusted for the `agent-core`
default branch and not for pull requests; `agent-core` CI pushes by digest and records it. Alternatives not
chosen: a registry owned by `agent-core` (splits ownership of the AWS account, against ADR 0003 item 1) and
pushing from pull requests (any contributor could publish an image that this repository might deploy).

## Facts checked in `agent-core` before writing

- Pull request #25 adds the Dockerfile, the `image` CI job (build, `--help`, uid 10001, no DSN/token/API key
  variables), `/version`, key reload (`--keys-reload-seconds`, default 5), `/v1/export/*` with the `exporter`
  role, and ADR 0022 (expand-only migrations).
- `agentcore sweep` still reads `AGENTCORE_DATABASE_URL` and needs `--registry`: the mismatch recorded in
  journal 0010 is unchanged.

## Verification

- RED first: `python -m unittest tests.test_agent_core_scope_contract` ran 10 tests with 4 failures and 1
  error (the new class).
- GREEN: `python -m unittest discover -s tests` -> `Ran 35 tests ... OK`.
- `terraform fmt` was not run locally (Terraform is not installed on this host); no `.tf` file changed and CI
  runs fmt/validate.

## Not done

No ECR repository, OIDC role, ECS resource, plan or apply. The staff-key issuer was not asked to mint an
`exporter` credential. The improvement-engine side (the `dependency_blocked` routes it keeps for these
requests, its contract-drift job and the previous-image schema smoke) lives in a repository that is not
part of this checkout and was not changed.
