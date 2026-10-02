mock_provider "aws" {}

variables {
  least_privilege_policy_boundary     = ""
  tags                                = { Environment = "test" }
  artifact_bucket_arn                 = "arn:aws:s3:::pulso-artifacts-test"
  source_bucket_arn                   = "arn:aws:s3:::pulso-source-test"
  runtime_secret_arn                  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-runtime-config-test"
  runtime_database_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-runtime-db-test"
  rds_master_secret_arn_guard         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  aws_region                          = "us-east-1"
  runtime_secret_kms_key_arn          = ""
  runtime_database_secret_kms_key_arn = ""
}

run "aws_managed_secret_key_never_grants_kms_decrypt" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role_policy.execution_secret.policy).Statement == [{
      Sid      = "ReadRuntimeSecret"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = [var.runtime_secret_arn]
    }]
    error_message = "The execution role may read only the runtime configuration secret when no customer KMS key is configured."
  }

  assert {
    condition = [
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement : statement
      if try(statement.Sid, "") == "ReadRuntimeDatabaseSecret"
      ] == [{
        Sid      = "ReadRuntimeDatabaseSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_database_secret_arn]
    }]
    error_message = "The task role may read only the external pulso_runtime database secret."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement :
      !contains(try(statement.Resource, []), var.rds_master_secret_arn_guard)
    ])
    error_message = "The RDS master secret must never be granted to the task role."
  }
}

run "customer_managed_key_is_bound_to_exact_secret_manager_context" {
  command = plan

  variables {
    runtime_secret_kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/01234567-89ab-cdef-0123-456789abcdef"
    runtime_database_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/fedcba98-7654-3210-fedc-ba9876543210"
  }

  assert {
    condition = [
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement : statement
      if try(statement.Sid, "") == "DecryptRuntimeDatabaseSecret"
      ] == [{
        Sid      = "DecryptRuntimeDatabaseSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.runtime_database_secret_kms_key_arn]
        Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${var.aws_region}.amazonaws.com"
            "kms:EncryptionContext:SecretARN" = var.runtime_database_secret_arn
          }
        }
    }]
    error_message = "A database-secret CMK grant must be scoped to the pulso_runtime secret only."
  }
}

run "rds_master_secret_cannot_be_used_as_runtime_database_secret" {
  command = plan

  variables {
    runtime_database_secret_arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  }

  expect_failures = [aws_iam_role_policy.task]
}

run "empty_runtime_database_secret_is_rejected" {
  command = plan

  variables {
    runtime_database_secret_arn = ""
  }

  expect_failures = [var.runtime_database_secret_arn]
}
