# Secret JSON keys (names only)

Secret `<name_prefix>/hackathon` (Secrets Manager, one secret, JSON object). Values are set out of band; Terraform seeds
`CHANGE_ME` (and the random `RDS_MASTER_PASSWORD`) and ignores later changes. Names marked (assumed) were not confirmed
with the owning team: they are module variables.

| Workload | Keys |
|---|---|
| database | `RDS_MASTER_PASSWORD`, `DB_PASSWORD_CORE_OWNER`, `_CORE_APP`, `_CORE_EVAL_APP`, `_CORE_EXPORTER_RO`, `_PULSO_APP`, `_PULSO_LOADER`, `_PULSO_RAW_RO`, `_PULSO_AUGMENTED_RO`, `_PULSO_PRODUCT_RO` |
| agent-core (`CORE__`) | `CORE__AGENTCORE_REGISTRY_DSN`, `CORE__AGENTCORE_EVAL_DSN`, `CORE__AGENTCORE_LLM_GATEWAY_TOKEN`, `CORE__PULSO_BRIDGE_CONTROL_SIGNER`, `CORE__PULSO_BRIDGE_LAB_SIGNER` (assumed, `bridge_signer_names`) |
| llm-gateway (`GATEWAY__`) | `GATEWAY__GATEWAY_TOKEN_AGENT_CORE`, `GATEWAY__GATEWAY_TOKEN_ENGINE`, `GATEWAY__GATEWAY_TOKEN_SUPPORT_PLATFORM` (`gateway_consumers`), `GATEWAY__OPENAI_API_KEY`, `GATEWAY__ANTHROPIC_API_KEY`, `GATEWAY__GOOGLE_API_KEY` (assumed, `llm_provider_key_names`), `GATEWAY__JEV_API_KEY` |
| support-platform (`SUPPORT__`) | `SUPPORT__CC_SESSION_SECRET`, `SUPPORT__CC_TOTP_SECRET_KEY`, `SUPPORT__CC_DATABASE_URL` |
| engine (`PULSO__`) | `PULSO__PULSO_DATABASE_URL`, `PULSO__PULSO_ADMIN_TOKEN` |

Host-consumed keys are `<SERVICE>__<VAR>`: the compute start script writes `<VAR>` into `/run/pulso/env/<service>.env` for the services of its own host (`CORE`, `GATEWAY` on the core host, `SUPPORT` on the platform host, `PULSO` on the engine host, `COMMON` on all). `DB_PASSWORD_*` and `RDS_MASTER_PASSWORD` carry no prefix and are never rendered into an env file. All three hosts can read the whole secret (one secret, one ARN): the prefix selects what a host renders, it is not an access boundary.

Non-secret configuration is in SSM Parameter Store (standard tier, free) under `/pulso/<workload>/<service>/<NAME>` (workload `core|platform|engine`, service `core|gateway|support|pulso|common`; each host role reads only `/pulso/<its workload>/*`):
agent-core `PULSO_LAB_BROKER_URL`, `PULSO_CONTROL_API_URL`, `PULSO_TENANT_ID`, `AGENTCORE_DAILY_BUDGET_USD`,
`AGENTCORE_BLOB_BUCKET` (derived `s3://<bucket>/core/blobs`); llm-gateway `GATEWAY_CONSUMERS`, `LLM_ENDPOINTS`;
support-platform `CC_CORS_ORIGINS`, `CC_PUBLIC_APP_URL`; engine `PULSO_DATA_MODE`, `PIPELINE_ROOT` (derived
`s3://<bucket>/lake`).

Host grant: `secretsmanager:GetSecretValue` on the single `secret_arn` output, and `ssm:GetParameter*` on
`ssm_parameter_arn_prefix/*`. The secret uses the AWS managed key `aws/secretsmanager` (no extra KMS cost). The data KMS key encrypts the S3 objects; the host roles hold `kms:Decrypt` and `kms:GenerateDataKey` on it.
