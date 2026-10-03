# RDS Proxy in front of the Agent Core database (ADR 0005). Every task keeps its own small connection pool;
# the proxy multiplexes them so the instance limit is not exhausted as tasks scale out.
#
# It authenticates with the externally bootstrapped application-role secret, never the RDS master secret.

locals {
  kms_statement = var.secret_kms_key_arn == "" ? [] : [{
    Sid      = "DecryptProxySecret"
    Effect   = "Allow"
    Action   = ["kms:Decrypt"]
    Resource = [var.secret_kms_key_arn]
    Condition = {
      StringEquals = {
        "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com"
      }
    }
  }]
}

resource "aws_iam_role" "proxy" {
  name_prefix = "${var.tags["Environment"]}-agent-core-proxy-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { Service = ["rds.amazonaws.com"] }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "proxy" {
  name = "read-application-database-secret"
  role = aws_iam_role.proxy.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Sid      = "ReadApplicationDatabaseSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.application_secret_arn]
    }], local.kms_statement)
  })

  lifecycle {
    precondition {
      condition     = var.application_secret_arn != var.rds_master_secret_arn_guard
      error_message = "The proxy must authenticate with the application secret, never the RDS master secret."
    }
  }
}

resource "aws_db_proxy" "this" {
  name                   = "${var.tags["Environment"]}-agent-core"
  engine_family          = "POSTGRESQL"
  role_arn               = aws_iam_role.proxy.arn
  vpc_subnet_ids         = var.private_subnet_ids
  vpc_security_group_ids = var.security_group_ids
  require_tls            = true
  idle_client_timeout    = var.idle_client_timeout_seconds
  debug_logging          = false

  auth {
    auth_scheme               = "SECRETS"
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
    iam_auth                  = "DISABLED"
    secret_arn                = var.application_secret_arn
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.proxy]
}

resource "aws_db_proxy_default_target_group" "this" {
  db_proxy_name = aws_db_proxy.this.name

  connection_pool_config {
    max_connections_percent      = var.max_connections_percent
    max_idle_connections_percent = var.max_idle_connections_percent
    connection_borrow_timeout    = var.connection_borrow_timeout_seconds
  }
}

resource "aws_db_proxy_target" "this" {
  db_proxy_name          = aws_db_proxy.this.name
  target_group_name      = aws_db_proxy_default_target_group.this.name
  db_instance_identifier = var.db_instance_identifier
}
