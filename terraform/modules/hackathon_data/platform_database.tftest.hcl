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

# Separate file: runs of one file share state and the secret version ignores later secret_string changes.

run "platform_database_is_off_by_default" {
  command = apply
  variables {
    agent_services_enabled = true
  }

  assert {
    condition     = !anytrue([for k in keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))) : can(regex("PLATFORM_(OWNER|APP|EXPORTER_RO)|TOOLS_(OWNER|APP)|CC_MIGRATE_DATABASE_URL|PG_PRODUCT_DSN", k))])
    error_message = "Without platform_database_enabled no platform or tools database key exists."
  }
}
