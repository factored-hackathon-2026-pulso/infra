# OTLP forwarder sidecars (decision B1)

The forwarder (improvement-engine `scripts/o11y/otlp_forwarder.py`) is the single egress to Langfuse Cloud for services that cannot do TLS to it or hold its keys. It listens on `127.0.0.1` only and has no bind option, so on every host it runs as a SIDECAR in the network namespace of its producer (`network_mode: "service:<producer>"`) and the producer exports to `http://127.0.0.1:4318`. OFF by default (`otlp_forwarder_enabled = false`); nothing applied, nothing run.

Checked by `tests/test_otlp_forwarder_contract.py` and the Terraform tests of `terraform/envs/hackathon`.

## Where the sidecars are

| Host | Sidecar | Shares the namespace of | Producer exports |
|---|---|---|---|
| core | `otlp-forwarder-gateway` | `llm-gateway` | Go OTel exporter: `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318`, content `LLM_GATEWAY_TRACE_CONTENT` |
| core | `otlp-forwarder-agent` | `agent-core` | `OTEL_EXPORTER_OTLP_ENDPOINT=http://127.0.0.1:4318`, protocol `http/protobuf`, `AGENTCORE_TRACE_LANGFUSE=1`, content `AGENTCORE_TRACE_CONTENT` |
| engine | `otlp-forwarder-engine` | `pulso` (and the loop job, when it is enabled) | `PULSO_O11Y_FORWARDER_ENDPOINT=http://127.0.0.1:4318`, content `PULSO_O11Y_CAPTURE_CONTENT` |

The engine binary has no OTLP exporter of its own today [U]: its story traces and scores are posted by the engine repo's `scripts/o11y/*` (a person, or a process inside the `pulso` namespace such as the loop job) to the forwarder. The forwarder accepts protobuf byte-exact (the Go gateway, agent-core) and masks OTLP JSON (bearer tokens, `sk-`/`pk-lf-` keys, JWTs, key=value secrets) before it forwards to `LANGFUSE_BASE_URL/api/public/otel/v1/traces` with Basic auth. The platform host has no sidecar: support-platform has no OTLP producer.

Files: `deploy/hackathon/core/compose.observability.yaml`, `deploy/hackathon/engine/compose.observability.yaml`, `deploy/hackathon/engine/compose.loop.observability.yaml` (the loop job joins the `pulso` namespace only when both features are on), image recipe `docker/otlp-forwarder.Dockerfile`.

## Langfuse keys: Secrets Manager, names only

| Name | Where | Who provides |
|---|---|---|
| `LANGFUSE__LANGFUSE_PUBLIC_KEY` | secret (`CHANGE_ME` placeholder) | human, from the Langfuse project |
| `LANGFUSE__LANGFUSE_SECRET_KEY` | secret (`CHANGE_ME` placeholder) | human |
| `LANGFUSE_BASE_URL` | SSM `/pulso/core/langfuse/` and `/pulso/engine/langfuse/` (not secret) | Terraform, from `langfuse_base_url` (default `https://us.cloud.langfuse.com`; https only) |

They render into `langfuse.env` on the core and engine hosts (service env `langfuse`) and are read ONLY by the sidecars: the producers never see them. The sidecar image bakes `PULSO_O11Y_ALLOW_EXTERNAL=1` (a non-loopback upstream needs it and https). A `CHANGE_ME` key does not stop the stack; Langfuse answers 401 and the forwarder drops the spans (visible in the sidecar log).

## Content flags

| Flag | Variable | Default | Effect |
|---|---|---|---|
| `LLM_GATEWAY_TRACE_CONTENT`, `AGENTCORE_TRACE_CONTENT`, `PULSO_O11Y_CAPTURE_CONTENT` | `otlp_trace_content` | `false` (`0`) | `1` exports prompts and responses (gateway spans carry the exact messages, up to a size cap; agent-core's `audit` view) |
| `AGENTCORE_TRACE_LANGFUSE` | none | `1` when the forwarder is on | derives the `langfuse.*` span attributes |

With content off only structure, timings and model/usage attributes leave the host. With it on, free text of customers can reach Langfuse (the engine repo's review notes the content switch is process-wide, not per consumer, and the masking is by pattern, not a redaction boundary). The owner authorized full content to Langfuse US; it is still one deliberate variable, not a default.

## Turn it on

```
otlp_forwarder_enabled = true
# images.core.forwarder and images.engine.forwarder = the same digest of the forwarder image
```

1. Build the image: the engine repo is the source zip, with `docker/otlp-forwarder.Dockerfile` of this repository added ([service-deployment](service-deployment.md#otlp-forwarder-otlp-forwarder-otlp-forwarder-only)); push to `pulso-prod/otlp-forwarder` (a bootstrap default repository).
2. Put the two Langfuse keys into the secret (`put-secret-value`, merge, never printed).
3. Plan and apply; `deploy-stack.sh` waits for the sidecars to be healthy (`/healthz`).

## What is not verified

The image was never built; no sidecar ran; protobuf export from the real gateway and agent-core into the real forwarder and Langfuse was exercised only by the engine team's local stack (`LANGFUSE_CLOSURE`), not here. The agent-core span attribute names come from `serve-env.md`; whether Langfuse Cloud accepts every request shape is the engine repo's finding, not re-tested.
