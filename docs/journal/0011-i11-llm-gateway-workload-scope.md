# I11 — LLM gateway workload scope

**Date:** 2026-10-03

## Objective

Make the repository documents say that this repository also deploys the `llm-gateway` service (ADR 0004), now
that the gateway left Agent Core and became its own repository. Documentation and a structural test only; no
Terraform, workflow, secret or AWS change.

## Change

- `docs/adr/0004-llm-gateway-workload.md`: scope, shape (stateless, private, no data store), egress ownership,
  interface contract (image digest, port and health, request deadline versus balancer idle timeout, variables,
  commands, observability), implementation status and open questions.
- `AGENTS.md`, `CONTEXT.md`, `README.md`: the gateway is a workload of this repository; the "does not own an LLM
  gateway" sentences are gone.
- `docs/architecture/deployment-status.md` and `docs/gaps/OPEN_GAPS.md`: the gateway row and section and three
  gaps (workload declaration, service-to-service ingress, secrets).
- `docs/adr/0003-agent-core-workload.md`: a pending-change note in the interface contract; the contract itself
  stays as written until Agent Core consumes the gateway.

## Update: JEV through the gateway

`llm-gateway` gained `POST /v1/jev` (a JEV pass-through that holds `JEV_API_KEY`, the retries and the egress to
`api.typesafe.ai`). ADR 0004 now lists that secret, the JEV settings and the JEV host as gateway concerns, and
ADR 0003's pending-change note includes `AGENTCORE_JEV_API_KEY`. Still documentation only.

## Facts checked in `llm-gateway` before writing

- Stateless Go service; listens on `LISTEN_ADDR` (default `:8080`); `GET /healthz` unauthenticated;
  `llm-gateway -healthcheck` for container checks; distroless non-root image.
- Reads `GATEWAY_CONSUMERS`, `LLM_ENDPOINTS` and the variables they name; exits non-zero at startup on a missing
  consumers variable, an empty token or a shared token.
- A call may last up to 300 seconds (`timeout_s`), which exceeds the default ALB idle timeout of 60 seconds.
- Its CI builds the image and probes `/healthz`; it does not publish a digest.

## Verification

- RED first: `python -m unittest tests.test_llm_gateway_scope_contract` failed 7 of 7 tests.
- `python -m unittest discover -s tests` → `Ran 37 tests ... OK` (30 existing + 7 new).
- `terraform fmt` was not run locally (Terraform is not installed on this host); no `.tf` file changed and CI
  runs fmt/validate on the pull request.

## Not done

No gateway resource, plan or apply; no claim that anything is deployed. Agent Core's `HttpLLMGateway` and the
deletion of its Python gateway are separate changes in `agent-core`.
