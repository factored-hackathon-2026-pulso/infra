mock_provider "aws" {}

variables {
  least_privilege_policy_boundary = ""
  tags = {
    Environment = "test"
  }
  artifact_bucket_arn        = "arn:aws:s3:::pulso-artifacts-test"
  source_bucket_arn          = "arn:aws:s3:::pulso-source-test"
  runtime_secret_arn         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-runtime-test"
  aws_region                 = "us-east-1"
  runtime_secret_kms_key_arn = ""
}

run "aws_managed_secret_key_never_grants_kms_decrypt" {
  command = plan

  assert {
    condition = jsondecode(aws_iam_role_policy.execution_secret.policy).Statement == [
      {
        Sid      = "ReadRuntimeSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_secret_arn]
      },
    ]
    error_message = "An empty customer-managed-key input must emit only exact-secret GetSecretValue."
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(aws_iam_role_policy.task.policy).Statement :
      alltrue([for action in statement.Action : startswith(action, "s3:")])
    ])
    error_message = "The task role must contain only S3 actions."
  }
}

run "customer_managed_key_is_bound_to_exact_secret_manager_context" {
  command = plan

  variables {
    runtime_secret_kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/01234567-89ab-cdef-0123-456789abcdef"
  }

  assert {
    condition = jsondecode(aws_iam_role_policy.execution_secret.policy).Statement == [
      {
        Sid      = "ReadRuntimeSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_secret_arn]
      },
      {
        Sid      = "DecryptRuntimeSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.runtime_secret_kms_key_arn]
        Condition = {
          StringEquals = {
            "kms:ViaService"                  = "secretsmanager.${var.aws_region}.amazonaws.com"
            "kms:EncryptionContext:SecretARN" = var.runtime_secret_arn
          }
        }
      },
    ]
    error_message = "A customer-managed KMS key must be usable only by Secrets Manager for this exact runtime secret, with no extra grants."
  }
}
