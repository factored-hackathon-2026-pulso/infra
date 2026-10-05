# Non-secret configuration skeleton: /pulso/<workload>/<service>/<VAR> (workload core|platform|engine; service = the
# env file the compute start script renders: common|core|gateway|support|pulso). The host IAM role reads <prefix>/<workload>/*. Placeholders are set out of band (ignore_changes).
# Names only for values that depend on the operator; bucket-derived values are real.

locals {
  ssm_prefix = "/pulso"

  ssm_placeholders = {
    # Legacy core-bridge keys: unused by `agentcore serve` (ADR 0009). Kept (empty placeholders) so an apply never destroys them.
    "core/core/PULSO_LAB_BROKER_URL"       = "CHANGE_ME"
    "core/core/PULSO_CONTROL_API_URL"      = "CHANGE_ME"
    "core/core/PULSO_TENANT_ID"            = "CHANGE_ME"
    "core/core/AGENTCORE_DAILY_BUDGET_USD" = "CHANGE_ME"
    "core/core/AGENTCORE_TOOL_SERVICE_URL" = "CHANGE_ME"
    "platform/support/CC_CORS_ORIGINS"     = "CHANGE_ME"
    "platform/support/CC_PUBLIC_APP_URL"   = "CHANGE_ME"
    "engine/pulso/PULSO_DATA_MODE"         = "CHANGE_ME"
  }

  # Gateway config: consumers name the env var that holds each token (the values are generated, generated.tf); the only
  # endpoint is the OpenRouter alias (models, temperature and prices ride in each request profile, not here).
  gateway_consumers_json = jsonencode({ for c in var.gateway_consumers : replace(lower(c), "_", "-") => { token_env = "GATEWAY_TOKEN_${c}" } })
  llm_endpoints_json     = jsonencode({ openrouter = { base_url = "https://openrouter.ai/api/v1", api_key_env = "OPENROUTER_API_KEY" } })

  ssm_derived = {
    "core/gateway/GATEWAY_CONSUMERS"   = local.gateway_consumers_json
    "core/gateway/LLM_ENDPOINTS"       = local.llm_endpoints_json
    "core/core/AGENTCORE_BLOB_BUCKET"  = "s3://${local.bucket_name}/core/blobs"
    "core/core/AGENTCORE_SERVE_AGENTS" = "recepcion,disputas,consultas,copiloto-asesor,constructor-chat"
    "engine/pulso/PIPELINE_ROOT"       = "s3://${local.bucket_name}/lake"
    # Engine -> shared Core credentials (the seed is the secret PULSO__PULSO_CORE_SIGNING_SEED): the kid and the principal.
    "engine/pulso/PULSO_CORE_KID"          = local.engine_kid
    "engine/pulso/PULSO_CORE_PRINCIPAL_ID" = "builder"
    "engine/pulso/PULSO_LLM_GATEWAY"       = "enabled"
  }
}

resource "aws_ssm_parameter" "placeholder" {
  for_each = local.ssm_placeholders
  name     = "${local.ssm_prefix}/${each.key}"
  type     = "String"
  value    = each.value
  tags     = var.tags

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "derived" {
  for_each = local.ssm_derived
  name     = "${local.ssm_prefix}/${each.key}"
  type     = "String"
  value    = each.value
  tags     = var.tags
}

# The two gateway values used to be out-of-band placeholders; they are derived now (same address kind, no destroy).
moved {
  from = aws_ssm_parameter.placeholder["core/gateway/GATEWAY_CONSUMERS"]
  to   = aws_ssm_parameter.derived["core/gateway/GATEWAY_CONSUMERS"]
}

moved {
  from = aws_ssm_parameter.placeholder["core/gateway/LLM_ENDPOINTS"]
  to   = aws_ssm_parameter.derived["core/gateway/LLM_ENDPOINTS"]
}
