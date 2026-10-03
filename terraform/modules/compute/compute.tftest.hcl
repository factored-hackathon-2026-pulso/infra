mock_provider "aws" {}

variables {
  image_digest                = "123456789012.dkr.ecr.us-east-1.amazonaws.com/improvement-engine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  private_subnet_ids          = ["subnet-0123456789abcdef0"]
  security_group_ids          = ["sg-0123456789abcdef0"]
  task_role_arn               = "arn:aws:iam::123456789012:role/pulso-task"
  execution_role_arn          = "arn:aws:iam::123456789012:role/pulso-execution"
  aws_region                  = "us-east-1"
  desired_count               = 0
  runtime_secret_arn          = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-runtime-config-test"
  database_endpoint           = "pulso.test.internal"
  runtime_database_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-runtime-db-test"
  rds_master_secret_arn_guard = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  log_group_name              = "/pulso/test/improvement-engine"
  tags                        = { Environment = "test" }
}

run "distinct_application_database_secret_is_accepted" {
  command = plan

  assert {
    condition     = aws_ecs_task_definition.this.container_definitions != null
    error_message = "A distinct application secret must allow task planning."
  }
}

run "rds_master_secret_cannot_be_used_as_runtime_database_secret" {
  command = plan

  variables {
    runtime_database_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "empty_runtime_database_secret_is_rejected" {
  command = plan

  variables {
    runtime_database_secret_arn = ""
  }

  expect_failures = [var.runtime_database_secret_arn]
}
