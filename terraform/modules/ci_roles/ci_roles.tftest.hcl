mock_provider "aws" {}

variables {
  github_oidc_provider_arn    = ""
  plan_subjects               = []
  apply_subjects              = []
  deploy_subjects             = []
  apply_policy_json           = ""
  permissions_boundary        = ""
  deploy_service_arns         = ["arn:aws:ecs:us-east-1:123456789012:service/test-pulso/pulso-core-runtime"]
  deploy_task_definition_arns = ["arn:aws:ecs:us-east-1:123456789012:task-definition/pulso-core-runtime:*"]
  deploy_cluster_arn          = "arn:aws:ecs:us-east-1:123456789012:cluster/test-pulso"
  passable_role_arns          = ["arn:aws:iam::123456789012:role/core-task", "arn:aws:iam::123456789012:role/core-exec"]
  tags                        = { Environment = "test" }
}

run "t08_no_role_exists_without_approved_inputs" {
  command = plan

  assert {
    condition     = length(aws_iam_role.ci_plan) == 0 && length(aws_iam_role.ci_apply) == 0 && length(aws_iam_role.deploy) == 0
    error_message = "ci-plan, ci-apply and deploy must have count=0 until the OIDC ARN and subjects are approved."
  }
}

run "provider_without_subjects_creates_nothing" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
  }

  assert {
    condition     = length(aws_iam_role.ci_plan) == 0 && length(aws_iam_role.deploy) == 0
    error_message = "Roles need both the provider ARN and exact subjects."
  }
}

run "subjects_without_provider_creates_nothing" {
  command = plan

  variables {
    plan_subjects = ["repo:pulso-factored/infra:pull_request"]
  }

  assert {
    condition     = length(aws_iam_role.ci_plan) == 0
    error_message = "Subjects alone must not create a role."
  }
}

run "plan_role_is_read_only_and_trusts_exact_subject" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    plan_subjects            = ["repo:pulso-factored/infra:pull_request"]
  }

  assert {
    condition     = length(aws_iam_role.ci_plan) == 1 && length(aws_iam_role.ci_apply) == 0
    error_message = "Only the plan role is enabled."
  }
  assert {
    condition     = jsondecode(aws_iam_role.ci_plan[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:sub"] == ["repo:pulso-factored/infra:pull_request"]
    error_message = "Trust must be an exact subject match, not StringLike."
  }
  assert {
    condition     = jsondecode(aws_iam_role.ci_plan[0].assume_role_policy).Statement[0].Condition.StringEquals["token.actions.githubusercontent.com:aud"] == "sts.amazonaws.com"
    error_message = "Audience must be sts.amazonaws.com."
  }
  assert {
    condition     = aws_iam_role_policy_attachment.ci_plan_read_only[0].policy_arn == "arn:aws:iam::aws:policy/ReadOnlyAccess"
    error_message = "The plan role is read-only and separate from apply."
  }
}

run "wildcard_subjects_are_rejected" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    apply_subjects           = ["repo:pulso-factored/*:*"]
  }

  expect_failures = [var.apply_subjects]
}

run "apply_role_needs_boundary_and_policy" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    apply_subjects           = ["repo:pulso-factored/infra:environment:staging"]
  }

  expect_failures = [aws_iam_role.ci_apply]
}

run "apply_role_with_approved_inputs_plans" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    apply_subjects           = ["repo:pulso-factored/infra:environment:staging"]
    apply_policy_json        = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":[\"ecs:Describe*\"],\"Resource\":\"*\"}]}"
    permissions_boundary     = "arn:aws:iam::123456789012:policy/pulso-boundary"
  }

  assert {
    condition     = aws_iam_role.ci_apply[0].permissions_boundary == "arn:aws:iam::123456789012:policy/pulso-boundary"
    error_message = "ci-apply must carry the permissions boundary."
  }
}

run "t09_deploy_role_is_bounded_and_passrole_is_limited" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    deploy_subjects          = ["repo:pulso-factored/infra:environment:staging"]
    permissions_boundary     = "arn:aws:iam::123456789012:policy/pulso-boundary"
  }

  assert {
    condition = jsonencode([
      for s in jsondecode(aws_iam_role_policy.deploy[0].policy).Statement : s.Resource
      if s.Sid == "PassTaskAndExecutionRolesToEcsOnly"
    ]) == jsonencode([var.passable_role_arns])
    error_message = "iam:PassRole must be limited to the task and execution roles."
  }
  assert {
    condition = [
      for s in jsondecode(aws_iam_role_policy.deploy[0].policy).Statement : s.Condition.StringEquals["iam:PassedToService"]
      if s.Sid == "PassTaskAndExecutionRolesToEcsOnly"
    ] == ["ecs-tasks.amazonaws.com"]
    error_message = "PassRole must require PassedToService=ecs-tasks.amazonaws.com."
  }
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.deploy[0].policy).Statement :
      !contains(s.Resource, "*")
    ])
    error_message = "No deploy statement may use a wildcard resource."
  }
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.deploy[0].policy).Statement :
      !contains(s.Action, "iam:*") && !contains(s.Action, "ecs:*")
    ])
    error_message = "No service-wide wildcard actions."
  }
}

run "deploy_role_without_boundary_is_rejected" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    deploy_subjects          = ["repo:pulso-factored/infra:environment:staging"]
  }

  expect_failures = [aws_iam_role.deploy]
}

# --- independent review (adversarial) findings ---

run "apply_subject_must_be_a_protected_environment" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    apply_subjects           = ["repo:pulso-factored/infra:pull_request"]
  }

  expect_failures = [var.apply_subjects]
}

run "deploy_subject_must_be_a_protected_environment" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    deploy_subjects          = ["repo:pulso-factored/infra:ref:refs/heads/feature-x"]
  }

  expect_failures = [var.deploy_subjects]
}

run "wildcard_passable_roles_are_rejected" {
  command = plan

  variables {
    passable_role_arns = ["arn:aws:iam::123456789012:role/*"]
  }

  expect_failures = [var.passable_role_arns]
}

run "wildcard_service_arns_are_rejected" {
  command = plan

  variables {
    deploy_service_arns = ["*"]
  }

  expect_failures = [var.deploy_service_arns]
}

run "wildcard_apply_policy_is_rejected" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    apply_subjects           = ["repo:pulso-factored/infra:environment:staging"]
    apply_policy_json        = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    permissions_boundary     = "arn:aws:iam::123456789012:policy/pulso-boundary"
  }

  expect_failures = [aws_iam_role.ci_apply]
}

run "plan_role_cannot_read_secret_values" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    plan_subjects            = ["repo:pulso-factored/infra:pull_request"]
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.ci_plan_deny_secret_reads[0].policy).Statement :
      s.Effect == "Deny" && contains(s.Action, "secretsmanager:GetSecretValue") && contains(s.Action, "ssm:GetParameter")
    ])
    error_message = "ci-plan must explicitly deny reading secret values (ReadOnlyAccess is broader than plan needs)."
  }
}

run "deploy_role_can_observe_the_tasks_it_starts" {
  command = plan

  variables {
    github_oidc_provider_arn = "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    deploy_subjects          = ["repo:pulso-factored/infra:environment:staging"]
    permissions_boundary     = "arn:aws:iam::123456789012:policy/pulso-boundary"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(aws_iam_role_policy.deploy[0].policy).Statement :
      contains(s.Action, "ecs:DescribeTasks") && !contains(s.Resource, "*")
    ])
    error_message = "The runbook waits on core-migrate exit codes; the deploy role needs ecs:DescribeTasks on this cluster tasks."
  }
}
