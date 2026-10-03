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
      Action   = ["s3:GetObject"]
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

# --- independent review (adversarial) findings ---

run "wildcard_secret_arns_are_rejected" {
  command = plan

  variables {
    own_secret_arns = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:*"]
  }

  expect_failures = [var.own_secret_arns]
}

run "bare_star_secret_arn_is_rejected" {
  command = plan

  variables {
    own_secret_arns = ["*"]
  }

  expect_failures = [var.own_secret_arns]
}

run "wildcard_kms_keys_are_rejected" {
  command = plan

  variables {
    secret_kms_key_arns = ["*"]
  }

  expect_failures = [var.secret_kms_key_arns]
}

run "task_statements_cannot_grant_privilege_escalation" {
  command = plan

  variables {
    task_statements = [{
      Effect   = "Allow"
      Action   = ["iam:PassRole"]
      Resource = ["arn:aws:iam::123456789012:role/x"]
    }]
  }

  expect_failures = [var.task_statements]
}

run "task_statements_cannot_use_a_global_wildcard_action" {
  command = plan

  variables {
    task_statements = [{
      Effect   = "Allow"
      Action   = "*"
      Resource = ["*"]
    }]
  }

  expect_failures = [var.task_statements]
}

run "task_statements_cannot_read_secrets_directly" {
  command = plan

  variables {
    task_statements = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = ["arn:aws:secretsmanager:us-east-1:123456789012:secret:other-workload-secret"]
    }]
  }

  expect_failures = [var.task_statements]
}

run "bounded_task_statement_is_accepted" {
  command = plan

  variables {
    task_statements = [{
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["arn:aws:s3:::pulso-artifacts-test/core/*"]
    }]
  }

  assert {
    condition     = length(aws_iam_role_policy.task) == 1
    error_message = "A bounded explicit statement must still be accepted."
  }
}

run "trust_is_bound_to_this_account_against_confused_deputy" {
  command = plan

  assert {
    condition     = contains(keys(jsondecode(aws_iam_role.task.assume_role_policy).Statement[0].Condition.StringEquals), "aws:SourceAccount")
    error_message = "ECS trust must carry aws:SourceAccount."
  }
  assert {
    condition     = contains(keys(jsondecode(aws_iam_role.execution.assume_role_policy).Statement[0].Condition.StringEquals), "aws:SourceAccount")
    error_message = "ECS trust must carry aws:SourceAccount."
  }
}

run "pass_role_is_an_explicit_exact_arn_grant_for_ecs_tasks_only" {
  command = plan

  variables {
    pass_role_arns = ["arn:aws:iam::123456789012:role/test-sandbox-task", "arn:aws:iam::123456789012:role/test-sandbox-exec"]
  }

  assert {
    condition = jsonencode(jsondecode(aws_iam_role_policy.pass_role[0].policy).Statement) == jsonencode([{
      Sid       = "PassOnlyNamedRolesToEcsTasks"
      Effect    = "Allow"
      Action    = ["iam:PassRole"]
      Resource  = var.pass_role_arns
      Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
    }])
    error_message = "iam:PassRole is limited to the named role ARNs and the ecs-tasks service."
  }
}

run "pass_role_rejects_wildcards" {
  command = plan

  variables {
    pass_role_arns = ["arn:aws:iam::123456789012:role/*"]
  }

  expect_failures = [var.pass_role_arns]
}

run "no_pass_role_policy_by_default" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy.pass_role) == 0
    error_message = "Existing consumers get no new policy (zero diff)."
  }
}
