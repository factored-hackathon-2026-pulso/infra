# Non-secret configuration skeleton: /pulso/<workload>/<service>/<VAR> (workload core|platform|engine; service = the
# env file the compute start script renders: common|core|gateway|support|pulso). The host IAM role reads <prefix>/<workload>/*. Placeholders are set out of band (ignore_changes).
# Names only for values that depend on the operator; bucket-derived values are real.

locals {
  ssm_prefix = "/pulso"

  ssm_placeholders = {
    "core/core/PULSO_LAB_BROKER_URL"       = "CHANGE_ME"
    "core/core/PULSO_CONTROL_API_URL"      = "CHANGE_ME"
    "core/core/PULSO_TENANT_ID"            = "CHANGE_ME"
    "core/core/AGENTCORE_DAILY_BUDGET_USD" = "CHANGE_ME"
    "platform/support/CC_CORS_ORIGINS"     = "CHANGE_ME"
    "platform/support/CC_PUBLIC_APP_URL"   = "CHANGE_ME"
  }

  # Gateway config: consumers name the env var that holds each token (the values are generated, generated.tf); the only
  # endpoint is the OpenRouter alias (models, temperature and prices ride in each request profile, not here).
  gateway_consumers_json = jsonencode({ for c in var.gateway_consumers : replace(lower(c), "_", "-") => { token_env = "GATEWAY_TOKEN_${c}" } })
  llm_endpoints_json     = jsonencode({ openrouter = { base_url = "https://openrouter.ai/api/v1", api_key_env = "OPENROUTER_API_KEY" } })

  ssm_derived = merge({
    "core/gateway/GATEWAY_CONSUMERS" = local.gateway_consumers_json
    "core/gateway/LLM_ENDPOINTS"     = local.llm_endpoints_json
    # Engine -> shared Core, named as the engine reads them (real_core.rs): kid here, seed hex in PULSO__PULSO_SERVICE_SEED_HEX.
    "engine/pulso/PULSO_SERVICE_KID" = local.engine_kid
    "engine/pulso/PULSO_LLM_GATEWAY" = "enabled"
    "engine/pulso/PULSO_BASE_PATH"   = "/pulso"
    # Bank aggregates (the dataset adapters); the platform events path is the other value, set by changing this parameter.
    "engine/pulso/PULSO_DATA_MODE"    = "dataset"
    "core/core/AGENTCORE_BLOB_BUCKET" = "s3://${local.bucket_name}/core/blobs"
    "engine/pulso/PIPELINE_ROOT"      = "s3://${local.bucket_name}/lake"
    },
    # The forwarder sidecars of the core and engine hosts read the Langfuse base URL from their own host slice.
    var.otlp_forwarder_enabled ? {
      "core/langfuse/LANGFUSE_BASE_URL"   = var.langfuse_base_url
      "engine/langfuse/LANGFUSE_BASE_URL" = var.langfuse_base_url
    } : {},
  )
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
