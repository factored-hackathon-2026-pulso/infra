# 0021 shared Core is agent-core serve: generated credentials and engine wiring (ADR 0009)

Rebuilt on top of main's agent services (journals 0019 and 0020); authoring and offline validation only.

- Terraform generates (like `origin_verify`) the gateway bearers per consumer (new consumer `AGENT_SERVE`), the grant and tool-service bearers, agent-core's HMAC keys and four Ed25519 keys; with `agent_services_enabled` they fill main's secret keys (`AGENT__*`, `TOOLS__TOOL_SERVICE_TOKENS`, `FILES__AGENT__IDENTITY_KEYS`/`STAFF_KEYS`, `FILES__SUPPORT__AGENT_PRIVATE_KEYS`); the engine gets `PULSO__PULSO_LLM_GATEWAY_KEY` and `PULSO__PULSO_SERVICE_SEED_HEX`. Seed and public key are derived from the provider PEM in HCL and pinned to RFC 8032 test vector 1 (`generated_credentials.tftest.hcl`).
- Engine addresses are SSM values built from the core host private IP (`PULSO_CORE_ADDR`, `PULSO_LLM_GATEWAY_ADDR`); SG rules core 8080 from engine, and 8001 from engine with the flag. `GATEWAY_CONSUMERS`/`LLM_ENDPOINTS` derived (moved blocks).
- `aws-prod.ps1 seed-secret-keys`: merge-only reseed of an existing secret over the sensitive output `generated_secrets`; `-replace` of the secret version documented as destructive.
- Dropped after merging main's PR 36: our own agent-core compose, `agent_core_serve_pieces`, artifact directories, platform grant-check listener and the core-runtime image change (main owns them).
- Validation: `terraform fmt -check`, `terraform test` in `modules/hackathon_data`, `hackathon_network`, `hackathon_compute`, `hackathon_iam`, `envs/hackathon`; `python -m unittest discover -s tests`; Pester `scripts/tests`.
