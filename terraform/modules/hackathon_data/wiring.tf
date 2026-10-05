# Wiring of every non-provider secret (docs/secrets-wiring.md). The only values a human types are the external provider keys
# (OpenRouter, JEV, optionally Langfuse). Everything here is generated once into the secret (like generated.tf: the secret version
# ignores later changes) or authored as a config file in deploy/hackathon/config. Nothing in this file is an output.
# Names only in docs and tests; values exist only in the Terraform state and the one Secrets Manager secret.

locals {
  db_container = var.database_mode == "container"

  # Role passwords: one random_password per role the secret carries (db_password_roles in secrets.tf). The container reads them from
  # db.env (initdb/10_init.sh, sql/00..30 \getenv); RDS mode keeps the unprefixed keys used by docs/db-bootstrap.md.
  db_pw = { for r in local.db_password_roles : r => random_password.db_role[r].result }

  # Hosts. Containers on the core host use the compose service name; the other hosts use the private zone record core.<zone>
  # (compose.postgres.yaml publishes 5432 to the platform and engine security groups only). RDS: the instance address everywhere.
  db_host_local  = local.db_container ? "postgres" : coalesce(one(aws_db_instance.this[*].address), "postgres")
  db_host_remote = local.db_container ? "core.${trimsuffix(var.private_zone_name, ".")}" : coalesce(one(aws_db_instance.this[*].address), "postgres")
  # No TLS inside the VPC for the container; RDS forces it (rds.force_ssl=1).
  db_query = local.db_container ? "?sslmode=disable" : "?sslmode=require"

  # DSN assembly. Passwords are alphanumeric (random_password special=false), so no URL encoding is needed.
  dsn = {
    for k, v in {
      core_app       = { role = "core_app", pw = try(local.db_pw["CORE_APP"], null), host = local.db_host_local, db = "core_runtime" }
      core_eval_app  = { role = "core_eval_app", pw = try(local.db_pw["CORE_EVAL_APP"], null), host = local.db_host_local, db = "core_eval" }
      agent_app      = { role = "agent_app", pw = try(local.db_pw["AGENT_APP"], null), host = local.db_host_local, db = "agent_runtime" }
      agent_app_eval = { role = "agent_app", pw = try(local.db_pw["AGENT_APP"], null), host = local.db_host_local, db = "agent_eval" }
      agent_owner    = { role = "agent_owner", pw = try(local.db_pw["AGENT_OWNER"], null), host = local.db_host_local, db = "agent_runtime" }
      agent_owner_ev = { role = "agent_owner", pw = try(local.db_pw["AGENT_OWNER"], null), host = local.db_host_local, db = "agent_eval" }
      platform_app   = { role = "platform_app", pw = try(local.db_pw["PLATFORM_APP"], null), host = local.db_host_remote, db = "platform" }
      platform_owner = { role = "platform_owner", pw = try(local.db_pw["PLATFORM_OWNER"], null), host = local.db_host_remote, db = "platform" }
      platform_exp   = { role = "platform_exporter_ro", pw = try(local.db_pw["PLATFORM_EXPORTER_RO"], null), host = local.db_host_remote, db = "platform" }
      # The engine migrates as the master first (its roles do not exist before its first start); docs/secrets-wiring.md.
      engine_master = { role = "pulso_master", pw = random_password.db_master.result, host = local.db_host_remote, db = "pulso" }
    } : k => "${try(v.scheme, "postgresql")}://${v.role}:${v.pw}@${v.host}:5432/${v.db}${try(v.query, local.db_query)}" if v.pw != null
  }

  # Fernet key (urlsafe base64 of 32 bytes, padded) for CC_TOTP_SECRET_KEY.
  totp_secret_key = replace(replace(random_bytes.totp.base64, "+", "-"), "/", "_")
  # Pseudonymisation HMAC key: 32 random bytes as 64 hex characters. Rotating it changes EVERY pseudonym (a planned re-publication).
  pseudonym_key = random_bytes.pseudonym.hex

  wired_always = {
    "CORE__AGENTCORE_REGISTRY_DSN" = local.dsn["core_app"]
    "CORE__AGENTCORE_EVAL_DSN"     = local.dsn["core_eval_app"]
    "PULSO__PULSO_DATABASE_URL"    = local.dsn["engine_master"]
    # Legacy core-bridge signers and the platform's session/TOTP secrets: random, never typed.
    "SUPPORT__CC_SESSION_SECRET"  = random_password.session_secret.result
    "SUPPORT__CC_TOTP_SECRET_KEY" = local.totp_secret_key
  }
  wired_bridge = { for n in var.bridge_signer_names : "CORE__${n}" => random_password.bridge_signer[n].result }

  wired_agents = var.agent_services_enabled ? {
    "AGENT__AGENTCORE_REGISTRY_DSN"       = local.dsn["agent_app"]
    "AGENT__AGENTCORE_EVAL_DSN"           = local.dsn["agent_app_eval"]
    "AGENT__AGENTCORE_MIGRATE_DSN"        = local.dsn["agent_owner"]
    "AGENT__AGENTCORE_MIGRATE_EVAL_DSN"   = local.dsn["agent_owner_ev"]
    "FILES__AGENT__FIELD_GRANTS"          = file("${path.module}/../../../deploy/hackathon/config/agent/field-grants.json")
    "FILES__AGENT__FIELD_OVERLAY"         = file("${path.module}/../../../deploy/hackathon/config/agent/field-overlay.json")
    "FILES__AGENT__LANG_THRESHOLDS"       = file("${path.module}/../../../deploy/hackathon/config/agent/lang-thresholds.json")
    "FILES__AGENT__FX_RATES"              = file("${path.module}/../../../deploy/hackathon/config/agent/fx-rates.json")
    "FILES__SUPPORT__BANK_CUSTOMER_LINKS" = file("${path.module}/../../../deploy/hackathon/config/support/bank-customer-links.json")
  } : {}

  wired_platform_db = var.platform_database_enabled ? {
    "SUPPORT__CC_DATABASE_URL"         = local.dsn["platform_app"]
    "MIGRATE__CC_DATABASE_URL" = local.dsn["platform_owner"]
    "PULSO__PULSO_PG_PRODUCT_DSN"      = local.dsn["platform_exp"]
  } : {}

  wired_loader = var.auto_loader_enabled ? { "LOADER__PSEUDONYM_KEY" = local.pseudonym_key } : {}

  # Role passwords go under the same key names db_password_keys uses.
  wired_db_passwords = { for r in local.db_password_roles : "${local.db_password_prefix}DB_PASSWORD_${r}" => local.db_pw[r] }

  wired_secrets = merge(local.wired_always, local.wired_bridge, local.wired_agents, local.wired_platform_db, local.wired_loader, local.wired_db_passwords)
}

resource "random_password" "db_role" {
  for_each = toset(local.db_password_roles)
  length   = 32
  special  = false
}

resource "random_password" "session_secret" {
  length  = 64
  special = false
}

resource "random_password" "bridge_signer" {
  for_each = toset(var.bridge_signer_names)
  length   = 48
  special  = false
}

# TOTP sealing key and pseudonymisation key: formats in docs/secrets-wiring.md.
resource "random_bytes" "totp" {
  length = 32
}

resource "random_bytes" "pseudonym" {
  length = 32
}
