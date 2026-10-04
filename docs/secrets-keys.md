# Secret JSON keys (names only)

Secret `<name_prefix>/hackathon` (Secrets Manager, one secret, JSON object). Values are set out of band; Terraform seeds
`CHANGE_ME` (and the random `RDS_MASTER_PASSWORD`) and ignores later changes. Names marked (assumed) were not confirmed
with the owning team: they are module variables.

| Workload | Keys |
|---|---|
| database | `RDS_MASTER_PASSWORD`, `DB_PASSWORD_CORE_OWNER`, `_CORE_APP`, `_CORE_EVAL_APP`, `_CORE_EXPORTER_RO`, `_PULSO_APP`, `_PULSO_LOADER`, `_PULSO_RAW_RO`, `_PULSO_AUGMENTED_RO`, `_PULSO_PRODUCT_RO` |
| agent-core | `AGENTCORE_REGISTRY_DSN`, `AGENTCORE_EVAL_DSN`, `AGENTCORE_LLM_GATEWAY_TOKEN`, `PULSO_BRIDGE_CONTROL_SIGNER`, `PULSO_BRIDGE_LAB_SIGNER` (assumed, `bridge_signer_names`) |
| llm-gateway | `GATEWAY_TOKEN_AGENT_CORE`, `GATEWAY_TOKEN_ENGINE`, `GATEWAY_TOKEN_SUPPORT_PLATFORM` (`gateway_consumers`), `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY` (assumed, `llm_provider_key_names`), `JEV_API_KEY` |
| support-platform | `CC_SESSION_SECRET`, `CC_TOTP_SECRET_KEY`, `CC_DATABASE_URL` |
| engine | `PULSO_DATABASE_URL`, `PULSO_ADMIN_TOKEN` |

Non-secret configuration is in SSM Parameter Store (standard tier, free) under `/pulso/<workload>/<NAME>`:
agent-core `PULSO_LAB_BROKER_URL`, `PULSO_CONTROL_API_URL`, `PULSO_TENANT_ID`, `AGENTCORE_DAILY_BUDGET_USD`,
`AGENTCORE_BLOB_BUCKET` (derived `s3://<bucket>/core/blobs`); llm-gateway `GATEWAY_CONSUMERS`, `LLM_ENDPOINTS`;
support-platform `CC_CORS_ORIGINS`, `CC_PUBLIC_APP_URL`; engine `PULSO_DATA_MODE`, `PIPELINE_ROOT` (derived
`s3://<bucket>/lake`).

Host grant: `secretsmanager:GetSecretValue` on the single `secret_arn` output, and `ssm:GetParameter*` on
`ssm_parameter_arn_prefix/*`. The secret uses the AWS managed key `aws/secretsmanager` (no extra KMS cost).
