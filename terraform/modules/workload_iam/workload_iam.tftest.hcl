mock_provider "aws" {}

variables {
  workload_name               = "pulso-core-runtime"
  aws_region                  = "us-east-1"
  own_secret_arns             = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-test", "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-keys-test"]
  secret_kms_key_arns         = []
  task_statements             = []
  rds_master_secret_arn_guard = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  permissions_boundary        = ""
  tags                        = { Environment = "test" }
}

run "execution_role_reads_only_its_own_secrets" {
  command = plan

  assert {
    condition = jsonencode(jsondecode(aws_iam_role_policy.execution_secrets.policy).Statement) == jsonencode([{
      Sid      = "ReadOwnSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.own_secret_arns
    }])
    error_message = "The execution role may read exactly the workload's own secrets."
  }
}

run "task_role_has_no_aws_permissions_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.task) == 0
    error_message = "A Core task has no AWS permissions unless explicitly granted."
  }
}

run "t07_master_secret_is_never_readable" {
  command = plan

  variables {
    own_secret_arns = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"]
  }

  expect_failures = [aws_iam_role_policy.execution_secrets]
}

run "t07_master_secret_with_suffix_is_never_readable" {
  command = plan

  variables {
    own_secret_arns = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test-AbCdEf"]
  }

  expect_failures = [aws_iam_role_policy.execution_secrets]
}

run "kms_decrypt_is_bound_to_secret_context" {
  command = plan

  variables {
    secret_kms_key_arns = ["arn:aws:kms:us-east-1:123456789012:key/01234567-89ab-cdef-0123-456789abcdef"]
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.execution_secrets.policy).Statement : s.Condition.StringEquals["kms:ViaService"]
      if try(s.Sid, "") == "DecryptOwnSecrets"
    ] == ["secretsmanager.us-east-1.amazonaws.com"]
    error_message = "kms:Decrypt must be limited to Secrets Manager via ViaService."
  }
  assert {
    condition = jsonencode([
      for s in jsondecode(aws_iam_role_policy.execution_secrets.policy).Statement : s.Condition.StringLike["kms:EncryptionContext:SecretARN"]
      if try(s.Sid, "") == "DecryptOwnSecrets"
    ]) == jsonencode([var.own_secret_arns])
    error_message = "kms:Decrypt must be bound to the workload's own secret ARNs."
  }
}

run "task_policy_statements_naming_the_master_secret_are_rejected" {
  command = plan

  variables {
    task_statements = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"]
    }]
  }

  expect_failures = [aws_iam_role_policy.task]
}

run "trust_is_ecs_tasks_only" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_role.task.assume_role_policy).Statement[0].Principal.Service == ["ecs-tasks.amazonaws.com"]
    error_message = "Only ECS tasks may assume workload roles."
  }
}
