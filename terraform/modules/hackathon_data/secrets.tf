# ONE Secrets Manager secret (JSON object) for everything sensitive; values other than the master password are set out
# of band (console or `put-secret-value`), Terraform never overwrites them. Key names: docs/secrets-keys.md.
# SSM Parameter Store (standard, free) holds only non-secret configuration.

resource "random_password" "db_master" {
  length  = 32
  special = false
}

resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

locals {
  db_password_keys = [for r in ["CORE_OWNER", "CORE_APP", "CORE_EVAL_APP", "CORE_EXPORTER_RO", "PULSO_APP", "PULSO_LOADER", "PULSO_RAW_RO", "PULSO_AUGMENTED_RO", "PULSO_PRODUCT_RO"] : "DB_PASSWORD_${r}"]

  # Host-consumed keys are <SERVICE>__<VAR>: the compute start script (pulso-stack-prepare) writes VAR into
  # /run/pulso/env/<service>.env for the services of its own host. DB_PASSWORD_* and RDS_MASTER_PASSWORD are for
  # docs/db-bootstrap.md and carry no prefix, so no host renders them into an env file.
  secret_keys = concat(
    # agent-core (compose service env "core")
    [for k in concat(["AGENTCORE_REGISTRY_DSN", "AGENTCORE_EVAL_DSN", "AGENTCORE_LLM_GATEWAY_TOKEN"], var.bridge_signer_names) : "CORE__${k}"],
    # llm-gateway (service env "gateway")
    [for k in concat([for c in var.gateway_consumers : "GATEWAY_TOKEN_${c}"], var.llm_provider_key_names, ["JEV_API_KEY"]) : "GATEWAY__${k}"],
    # support-platform (service env "support")
    [for k in ["CC_SESSION_SECRET", "CC_TOTP_SECRET_KEY", "CC_DATABASE_URL"] : "SUPPORT__${k}"],
    # engine (service env "pulso")
    [for k in ["PULSO_DATABASE_URL", "PULSO_ADMIN_TOKEN"] : "PULSO__${k}"],
    # CloudFront -> Caddy shared header value, rendered into common.env on every host
    ["COMMON__ORIGIN_VERIFY"],
    # Postgres container (free_plan): superuser password, rendered into db.env on the core host
    var.database_mode == "container" ? ["DB__POSTGRES_PASSWORD"] : [],
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
    { RDS_MASTER_PASSWORD = random_password.db_master.result, COMMON__ORIGIN_VERIFY = random_password.origin_verify.result },
    var.database_mode == "container" ? { DB__POSTGRES_PASSWORD = random_password.db_master.result } : {},
  ))

  lifecycle {
    ignore_changes = [secret_string]
  }
}
