mock_provider "aws" {}

variables {
  aws_region                  = "us-east-1"
  db_instance_identifier      = "agent-core-db"
  private_subnet_ids          = ["subnet-0123456789abcdef0"]
  security_group_ids          = ["sg-0123456789abcdef0"]
  application_secret_arn      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:agent-core-app-test"
  rds_master_secret_arn_guard = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  tags                        = { Environment = "test" }
}

run "proxy_requires_tls_and_uses_the_application_secret" {
  command = plan

  assert {
    condition     = aws_db_proxy.this.require_tls
    error_message = "Clients must connect over TLS."
  }

  assert {
    condition     = one(aws_db_proxy.this.auth).secret_arn == var.application_secret_arn
    error_message = "The proxy must authenticate with the application secret."
  }
}

run "the_rds_master_secret_is_refused" {
  command = plan

  variables {
    application_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  }

  expect_failures = [aws_iam_role_policy.proxy]
}

run "an_empty_secret_is_refused" {
  command = plan

  variables {
    application_secret_arn = ""
  }

  expect_failures = [var.application_secret_arn]
}
