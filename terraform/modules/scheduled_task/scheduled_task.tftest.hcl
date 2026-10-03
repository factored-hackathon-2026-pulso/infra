mock_provider "aws" {}

variables {
  name                                 = "core-sweep"
  cluster_arn                          = "arn:aws:ecs:us-east-1:123456789012:cluster/test-pulso"
  task_definition_arn_without_revision = "arn:aws:ecs:us-east-1:123456789012:task-definition/pulso-core-sweep"
  task_role_arns                       = ["arn:aws:iam::123456789012:role/core-exec", "arn:aws:iam::123456789012:role/core-task"]
  subnet_ids                           = ["subnet-0123456789abcdef0"]
  security_group_ids                   = ["sg-0123456789abcdef0"]
  tags                                 = { Environment = "test" }
}

run "the_task_never_gets_a_public_ip" {
  command = plan

  assert {
    condition     = one(one(one(aws_scheduler_schedule.this.target).ecs_parameters).network_configuration).assign_public_ip == false
    error_message = "Scheduled tasks stay private."
  }
}

run "the_scheduler_may_only_pass_the_listed_roles_to_ecs" {
  command = plan

  assert {
    condition     = strcontains(aws_iam_role_policy.scheduler.policy, "ecs-tasks.amazonaws.com") && strcontains(aws_iam_role_policy.scheduler.policy, "role/core-exec")
    error_message = "iam:PassRole is limited to the task roles and to ecs-tasks."
  }
}

run "a_task_definition_with_a_revision_is_refused" {
  command = plan

  variables {
    task_definition_arn_without_revision = "arn:aws:ecs:us-east-1:123456789012:task-definition/pulso-core-sweep:7"
  }

  expect_failures = [var.task_definition_arn_without_revision]
}

run "disabling_pauses_the_schedule" {
  command = plan

  variables {
    enabled = false
  }

  assert {
    condition     = aws_scheduler_schedule.this.state == "DISABLED"
    error_message = "enabled = false must pause the schedule."
  }
}
