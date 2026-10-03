mock_provider "aws" {}

# command = apply against a mock provider: no AWS call is made. It is needed because the worker launch
# policy embeds role ARNs that are unknown until the (mocked) apply.

variables {
  environment_name                = "test"
  aws_region                      = "us-east-1"
  source_bucket_arn               = "arn:aws:s3:::pulso-source-test"
  artifact_bucket_arn             = "arn:aws:s3:::pulso-artifacts-test"
  sandbox_session_prefix          = "sandbox/sessions"
  sandbox_results_prefix          = "sandbox/results"
  sandbox_task_definition_arn     = "arn:aws:ecs:us-east-1:123456789012:task-definition/sandbox-lab:*"
  sandbox_enabled                 = false
  worker_task_role_name           = "worker-task"
  observability_reader_principals = []
  permissions_boundary            = ""
  tags                            = { Environment = "test" }
}

run "sandbox_and_reader_are_absent_by_default" {
  command = apply

  assert {
    condition     = length(aws_iam_role.task_sandbox) == 0 && length(aws_iam_role.sandbox_execution) == 0 && length(aws_iam_policy.worker_sandbox_launch) == 0 && length(aws_iam_role.observability_reader) == 0
    error_message = "Sandbox (CLQ-43) and reader roles must not exist until enabled."
  }
}

run "t08_sandbox_denies_source_bucket_secrets_ecs_iam" {
  command = apply

  variables {
    sandbox_enabled = true
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.task_sandbox[0].policy).Statement :
      s.Effect == "Deny" && contains(s.Resource, var.source_bucket_arn) && contains(s.Resource, "${var.source_bucket_arn}/*")
    ])
    error_message = "task-sandbox needs an explicit Deny on the source bucket."
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.task_sandbox[0].policy).Statement :
      s.Effect == "Deny" && contains(s.Action, "secretsmanager:*") && contains(s.Action, "ecs:*") && contains(s.Action, "iam:*")
    ])
    error_message = "task-sandbox needs an explicit Deny on secrets, ecs and iam."
  }
  assert {
    condition = jsonencode([
      for s in jsondecode(aws_iam_role_policy.task_sandbox[0].policy).Statement : s.Resource
      if s.Sid == "ReadSessionPrefix"
    ]) == jsonencode([["${var.artifact_bucket_arn}/sandbox/sessions/*"]])
    error_message = "GetObject only on the session prefix."
  }
  assert {
    condition = jsonencode([
      for s in jsondecode(aws_iam_role_policy.task_sandbox[0].policy).Statement : s.Resource
      if s.Sid == "WriteResultsPrefix"
    ]) == jsonencode([["${var.artifact_bucket_arn}/sandbox/results/*"]])
    error_message = "PutObject only on the results prefix."
  }
}

run "t09_worker_launch_passrole_limited_to_sandbox_roles" {
  command = apply

  variables {
    sandbox_enabled = true
  }

  assert {
    condition = [
      for s in jsondecode(aws_iam_policy.worker_sandbox_launch[0].policy).Statement : s.Condition.StringEquals["iam:PassedToService"]
      if s.Sid == "PassSandboxRolesToEcsOnly"
    ] == ["ecs-tasks.amazonaws.com"]
    error_message = "PassRole must carry PassedToService=ecs-tasks.amazonaws.com."
  }
  assert {
    condition = [
      for s in jsondecode(aws_iam_policy.worker_sandbox_launch[0].policy).Statement : length(s.Resource)
      if s.Sid == "PassSandboxRolesToEcsOnly"
    ] == [2]
    error_message = "PassRole is limited to exactly the two sandbox roles."
  }
  assert {
    condition = jsonencode([
      for s in jsondecode(aws_iam_policy.worker_sandbox_launch[0].policy).Statement : s.Resource
      if s.Sid == "RunSandboxTaskOnly"
    ]) == jsonencode([[var.sandbox_task_definition_arn]])
    error_message = "RunTask only on the sandbox-lab task definition."
  }
}

run "observability_reader_is_read_only_on_pulso_log_groups" {
  command = apply

  variables {
    observability_reader_principals = ["arn:aws:iam::123456789012:role/oncall"]
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.observability_reader[0].policy).Statement :
      s.Effect == "Allow" && alltrue([for a in s.Action : can(regex("^(logs|cloudwatch):(Get|Describe|List|Filter|StartQuery|StopQuery)", a))])
    ])
    error_message = "The reader may only perform read actions."
  }
  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.observability_reader[0].policy).Statement :
      contains(s.Resource, "arn:aws:logs:us-east-1:*:log-group:/pulso/test/*")
    ])
    error_message = "Log reads are scoped to /pulso/<env>/*."
  }
}
