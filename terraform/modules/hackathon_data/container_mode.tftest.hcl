mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix   = "pulso-hk"
  region        = "us-east-1"
  vpc_id        = "vpc-0123456789abcdef0"
  db_subnet_ids = ["subnet-aaaa1111", "subnet-bbbb2222"]
  sg_db_id      = "sg-0123456789abcdef0"
}

# Separate file: test runs of one file share state and the secret version ignores later secret_string changes.

run "container_mode_creates_no_rds_and_keeps_the_password_in_the_secret" {
  command = apply
  variables {
    database_mode = "container"
    db_subnet_ids = []
    sg_db_id      = null
  }

  assert {
    condition     = length(aws_db_instance.this) == 0 && length(aws_db_subnet_group.this) == 0 && length(aws_db_parameter_group.this) == 0
    error_message = "database_mode=container creates no RDS resource."
  }
  assert {
    condition     = contains(keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))), "DB__POSTGRES_PASSWORD") && contains(keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))), "RDS_MASTER_PASSWORD")
    error_message = "The container superuser password (DB__POSTGRES_PASSWORD, rendered into db.env on the core host) comes from the single secret."
  }
  assert {
    condition     = output.db_endpoint == null
    error_message = "No RDS endpoint in container mode."
  }
  assert {
    condition     = contains(keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))), "DB__DB_PASSWORD_CORE_OWNER") && !contains(keys(nonsensitive(jsondecode(aws_secretsmanager_secret_version.this.secret_string))), "DB_PASSWORD_CORE_OWNER")
    error_message = "Role passwords are DB__DB_PASSWORD_* in container mode (rendered into db.env for the initdb script)."
  }
}
