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
    "core/gateway/GATEWAY_CONSUMERS"       = "CHANGE_ME"
    "core/gateway/LLM_ENDPOINTS"           = "CHANGE_ME"
    "platform/support/CC_CORS_ORIGINS"     = "CHANGE_ME"
    "platform/support/CC_PUBLIC_APP_URL"   = "CHANGE_ME"
    "engine/pulso/PULSO_DATA_MODE"         = "CHANGE_ME"
  }

  ssm_derived = {
    "core/core/AGENTCORE_BLOB_BUCKET" = "s3://${local.bucket_name}/core/blobs"
    "engine/pulso/PIPELINE_ROOT"      = "s3://${local.bucket_name}/lake"
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
