# Non-secret configuration skeleton: /pulso/<workload>/<service>/<VAR> (workload core|platform|engine; service = the
# env file the compute start script renders: common|core|gateway|support|pulso). The host IAM role reads <prefix>/<workload>/*. Placeholders are set out of band (ignore_changes).
# Names only for values that depend on the operator; bucket-derived values are real.

locals {
  ssm_prefix = "/pulso"

  # Legacy core-bridge values (lab broker, control API, tenant, budget): read only by the core-bridge services, which agent services
  # replace (ADR 0009). They stay out-of-band placeholders ONLY without agent_services_enabled. CC_CORS_ORIGINS and CC_PUBLIC_APP_URL
  # are derived in the environment root (they need the CloudFront domain, which depends on this module).
  ssm_placeholders = var.agent_services_enabled ? {} : {
    "core/core/PULSO_LAB_BROKER_URL"       = "CHANGE_ME"
    "core/core/PULSO_CONTROL_API_URL"      = "CHANGE_ME"
    "core/core/PULSO_TENANT_ID"            = "CHANGE_ME"
    "core/core/AGENTCORE_DAILY_BUDGET_USD" = "CHANGE_ME"
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
    # Models of the `pulso loop` roles (improvement-engine reasoning/live.rs): non-secret, derived (update in place), read at the next prepare/deploy.
    "engine/pulso/PULSO_LLM_GATEWAY_MODEL"                    = var.engine_llm_models.scout
    "engine/pulso/PULSO_LLM_GATEWAY_VERIFIER_MODEL"           = var.engine_llm_models.verifier
    "engine/pulso/PULSO_LLM_GATEWAY_BUILDER_MODEL"            = var.engine_llm_models.builder
    "engine/pulso/PULSO_LLM_GATEWAY_BUILDER_ESCALATION_MODEL" = var.engine_llm_models.builder_escalation
    # dataset = bank aggregates (dataset adapters); platform = the platform event log (product-postgres, set in the environment root
    # with platform_database_enabled). The engine refuses a mode/adapter mismatch at startup. Derived: updates in place on apply.
    "engine/pulso/PULSO_DATA_MODE"    = var.engine_data_mode
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
