# ONE Secrets Manager secret (JSON object) for everything sensitive; values other than the master password are set out
# of band (console or `put-secret-value`), Terraform never overwrites them. Key names: docs/secrets-keys.md.
# SSM Parameter Store (standard, free) holds only non-secret configuration.

resource "random_password" "db_master" {
  length  = 32
  special = false
}

locals {
  db_password_keys = [for r in ["CORE_OWNER", "CORE_APP", "CORE_EVAL_APP", "CORE_EXPORTER_RO", "PULSO_APP", "PULSO_LOADER", "PULSO_RAW_RO", "PULSO_AUGMENTED_RO", "PULSO_PRODUCT_RO"] : "DB_PASSWORD_${r}"]

  secret_keys = concat(
    # agent-core
    ["AGENTCORE_REGISTRY_DSN", "AGENTCORE_EVAL_DSN", "AGENTCORE_LLM_GATEWAY_TOKEN"],
    var.bridge_signer_names,
    # llm-gateway
    [for c in var.gateway_consumers : "GATEWAY_TOKEN_${c}"],
    var.llm_provider_key_names,
    ["JEV_API_KEY"],
    # support-platform
    ["CC_SESSION_SECRET", "CC_TOTP_SECRET_KEY", "CC_DATABASE_URL"],
    # engine
    ["PULSO_DATABASE_URL", "PULSO_ADMIN_TOKEN"],
    # database role passwords (used by docs/db-bootstrap.md)
    local.db_password_keys,
  )

  secret_placeholders = { for k in local.secret_keys : k => "CHANGE_ME" }
}

resource "aws_secretsmanager_secret" "this" {
  name                    = "${var.name_prefix}/hackathon"
  description             = "All sensitive values of the hackathon host (JSON). Values set out of band."
  recovery_window_in_days = 7
  tags                    = var.tags
}

resource "aws_secretsmanager_secret_version" "this" {
  secret_id = aws_secretsmanager_secret.this.id
  secret_string = jsonencode(merge(
    local.secret_placeholders,
    { RDS_MASTER_PASSWORD = random_password.db_master.result },
  ))

  lifecycle {
    ignore_changes = [secret_string]
  }
}
