# I10 — Agent Core scope alignment

**Date:** 2026-10-02

## Objective

Make the repository documents agree with ADR 0003 (accepted when pulso-factored/infra#11 merged): this
repository also deploys Agent Core. Documentation only; no Terraform, workflow, secret or AWS change.

## Change

- `AGENTS.md`, `CONTEXT.md`, `README.md`: Agent Core is a workload of this repository (ADR 0003); its code,
  image build, schema, migrations and runtime behavior stay in `agent-core`. The README states that it is
  **not declared in Terraform yet**.
- `docs/adr/0003-agent-core-workload.md`: status `Accepted`; engines and egress reconciled with the
  declared ECS/RDS and the `egress_profile` contract; new "Implementation status" section.
- `docs/architecture/deployment-status.md` and `docs/gaps/OPEN_GAPS.md`: the Agent Core row, section and four
  gaps (workload declaration, JEV data residency, runtime secrets, operation outside demo mode).

## Facts checked in `agent-core` before writing the ADR status

- Merged in pulso-factored/agent-core#19: `GET /healthz`, `GET /readyz` and `agentcore migrate`.
- No Dockerfile or image CI exists there.
- `agentcore sweep` reads `AGENTCORE_DATABASE_URL` and needs `--registry <authoring directory>`; `serve` and
  `migrate` read `AGENTCORE_REGISTRY_DSN`. Recorded as a mismatch to fix before scheduling the sweep.
- Outside demo mode `serve` requires pieces that do not exist yet, so a deployment can only run in demo mode.

## Verification

- RED first: `python -m unittest tests.test_agent_core_scope_contract` failed all 5 tests.
- `python -m unittest discover -s tests` → `Ran 30 tests ... OK`.
- `terraform fmt` was not run locally (Terraform is not installed on this host); no `.tf` file changed and CI
  runs fmt/validate on the pull request.

## Not done

No Agent Core resource, plan or apply; no claim that anything is deployed. The existing stale sentence in
`CONTEXT.md` ("deferred compute/database") predates this slice and was left as is.
