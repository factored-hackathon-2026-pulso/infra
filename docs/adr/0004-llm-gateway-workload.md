# The LLM gateway as a deployed workload

Status: **Accepted** by merging the pull request that adds it. Accepting the ADR creates no resources: see
"Implementation status".

## Context

ADR 0003 scoped this repository to the improvement engine and Agent Core, and the scope documents said it
does not own "an LLM gateway". That sentence described the gateway as a library inside Agent Core
(`agent_core/adapters/llm`, agent-core ADR 0016).

The gateway is now its own service, `pulso-factored/llm-gateway`: a stateless HTTP service in Go that calls
OpenAI-compatible endpoints and is consumed by Agent Core and by services in other languages (its design is
in that repository: `docs/adr/0001-llm-gateway-as-a-standalone-http-service.md`). It needs a place to run in
`staging` and `prod`, on the same foundation as the other workloads, for the same reason ADR 0003 gave:
rebuilding network, identity and secrets plumbing in a second repository would split ownership of one AWS
account.

ADR 0003 assumed Agent Core calls model providers itself: it lists `LLM_ENDPOINTS` and one key per endpoint
among Agent Core's secrets and the provider hosts among its egress hosts. It also lists
`AGENTCORE_JEV_API_KEY` and the host `api.typesafe.ai` (JEV, the decision-model provider). Once Agent Core
consumes the gateway, all of that moves: the gateway also forwards JEV calls (`POST /v1/jev`), holding the key
and doing the retries, so JEV stops being a direct dependency of Agent Core.

## Decision

1. **Scope.** This repository also owns the Terraform/AWS infrastructure that *runs* the gateway. It does not
   own the gateway's code, image build, API contract or runtime behavior; those stay in `llm-gateway`.
2. **Shape.** A third *workload* on the shared foundation, next to `improvement-engine` and `agent-core`, with
   its own ECS service, task role and security group. It is **stateless**: no RDS instance, no S3 bucket, no
   volume. Its task role needs no AWS API permission beyond what ECS requires to start it and write logs.
3. **Reachability.** Private only. Consumers reach it through an internal path (internal load balancer or
   service discovery; the choice is open). It is never exposed publicly and there is no API Gateway. Consumer
   authentication is a per-consumer Bearer token enforced by the service, over TLS.
4. **Egress.** The gateway is the only workload that calls model providers and JEV, so it is the one that needs
   the `controlled_nat` egress profile, with destination control for exactly the hosts in its `LLM_ENDPOINTS`
   plus the JEV host (`api.typesafe.ai` unless `JEV_BASE_URL` says otherwise). When Agent Core consumes the
   gateway it needs no external egress for models, only the gateway.
5. **Secrets.** Terraform provisions the entries (names and encryption only); values are set out of band, as
   in ADR 0003.
6. **Environments, region, apply.** Unchanged: `staging` and `prod` only, `us-east-1` provisionally, and no
   automated apply.

## Interface contract between the repositories

Both sides must change this table in the same pair of pull requests.

1. **Image.** `llm-gateway` publishes an immutable digest (distroless, non-root). This repository deploys only
   a digest, never a tag.
2. **Network.** One container port (default `8080`, `LISTEN_ADDR`). `GET /healthz` is liveness and also serves
   as readiness: the service is stateless and has no dependency to check at startup. It is unauthenticated and
   exposes no data. The image also ships `llm-gateway -healthcheck` for a container-level check.
3. **Request deadline.** A call may legitimately take up to 300 seconds (`timeout_s`, default 8; `timeout_ms`
   of `/v1/jev`, default 10 seconds, also up to 300). Any load
   balancer in front must set an idle timeout above that, or consumers must keep `timeout_s` below the
   balancer's idle timeout (the ALB default is 60 seconds).
4. **Configuration and secrets**, injected as environment variables:

   | Variable | Kind | Content |
   |---|---|---|
   | `GATEWAY_CONSUMERS` | plain | JSON `{consumer: {token_env}}`: names only |
   | One variable per consumer (the `token_env` value) | secret | that consumer's Bearer token |
   | `LLM_ENDPOINTS` | plain | JSON `{alias: {base_url, api_key_env}}`: names and URLs only |
   | One variable per endpoint (the `api_key_env` value) | secret | that provider's API key |
   | `JEV_API_KEY` | secret | the JEV API key used by `POST /v1/jev` |
   | `JEV_BASE_URL`, `JEV_MAX_RETRIES`, `JEV_BACKOFF_MS` | plain, optional | default `https://api.typesafe.ai` (https only), `3`, `250` |
   | `OTEL_EXPORTER_OTLP_ENDPOINT`, `OTEL_SERVICE_NAME`, … | plain | standard OpenTelemetry variables |

   The service exits non-zero at startup when `GATEWAY_CONSUMERS` is missing, a token variable is empty or two
   consumers share a token.
5. **Egress hosts.** Each host in `LLM_ENDPOINTS` and the JEV host.
6. **Commands.** None: no migration, no scheduled task.
7. **Observability.** JSON logs on stdout without prompts, inputs, model output, keys, tokens or provider
   messages; OTLP traces with the GenAI attributes when `OTEL_EXPORTER_OTLP_ENDPOINT` is set.

## Implementation status

Nothing for the LLM gateway is declared in Terraform and nothing is deployed.

- **Delivered in `llm-gateway`:** the service, `Dockerfile`, a CI that builds the image and probes `/healthz`,
  and the OpenAPI contract.
- **Missing in `llm-gateway`:** an image CI that publishes a digest to a registry.
- **Missing here:** ECR repository, ECS service and task definition (pinned to a digest), security groups, the
  secret entries, the internal ingress and the egress design.
- **Not yet consumed:** Agent Core still carries its own Python gateway; its `HttpLLMGateway` is a separate
  change. Until it lands, the ADR 0003 contract (Agent Core holds `LLM_ENDPOINTS` and the provider keys)
  stays in force.

## Consequences

- AGENTS.md, CONTEXT.md and the README name the gateway as a workload of this repository, and the "does not
  own an LLM gateway" sentences go away.
- The gateway slice needs the image digest, the contract items above, the egress design ("Controlled external
  egress" gap) and an ingress decision; the prerequisites are in `docs/gaps/OPEN_GAPS.md`.
- When Agent Core's `HttpLLMGateway` lands, ADR 0003's contract changes in the same pair of pull requests: the
  `LLM_ENDPOINTS`, per-endpoint key and `AGENTCORE_JEV_API_KEY` rows, and the provider and JEV hosts in the
  egress item, move to this ADR, and Agent Core gets the gateway URL and its own consumer token.
- One more service to deploy, but with no data at rest, its blast radius is small.

## Open questions

- Internal load balancer or service discovery for consumer access, and who terminates TLS.
- Whether Agent Core, the improvement engine and future consumers share one gateway per environment (assumed)
  or whether an isolation need justifies more.
- Size and scaling: not measured yet, so no CPU/memory numbers are asserted here.
