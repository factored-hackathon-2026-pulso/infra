mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix   = "pulso-hk"
  region        = "us-east-1"
  vpc_id        = "vpc-0123456789abcdef0"
  database_mode = "container"
  db_subnet_ids = []
  sg_db_id      = null
}

# Separate file: the secret version ignores later secret_string changes, so each secret shape needs its own file.

run "platform_database_seeds_roles_dsns_and_the_engine_token" {
  command = apply
  variables {
    agent_services_enabled    = true
    platform_database_enabled = true
  }

  assert {
    condition = alltrue([for k in [
      "DB__DB_PASSWORD_PLATFORM_OWNER", "DB__DB_PASSWORD_PLATFORM_APP", "DB__DB_PASSWORD_PLATFORM_EXPORTER_RO",
      "DB__DB_PASSWORD_TOOLS_OWNER", "DB__DB_PASSWORD_TOOLS_APP",
      "SUPPORT__CC_DATABASE_URL", "MIGRATE__CC_DATABASE_URL", "PULSO__PULSO_PG_PRODUCT_DSN",
    ] : contains(keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))), k)])
    error_message = "Role passwords (container mode, DB__ prefix), platform DSNs and the engine's read-only DSN are seeded."
  }
  assert {
    condition     = nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))["PULSO__PULSO_PG_PRODUCT_DSN"] != "CHANGE_ME"
    error_message = "DSNs are assembled by Terraform from the generated passwords."
  }
  assert {
    condition     = nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))["PULSO__PULSO_PLATFORM_SERVICE_TOKEN"] == nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))["SUPPORT__CC_INTERNAL_SERVICE_TOKEN"]
    error_message = "The engine presents the platform's own internal service bearer to the announce route."
  }
  assert {
    condition = alltrue([for k in keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))) :
    can(regex("^(CORE|GATEWAY|SUPPORT|PULSO|COMMON|AGENT|TOOLS|DB)__[A-Z0-9_]+$", k)) || can(regex("^FILES__(AGENT|SUPPORT)__[A-Z0-9_]+$", k)) || k == "RDS_MASTER_PASSWORD"])
    error_message = "Every key is <SERVICE>__<VAR> or FILES__<SERVICE>__<NAME>."
  }
}
