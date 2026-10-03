# Runs an existing ECS task definition (no service) on a schedule with EventBridge Scheduler, for example
# `agentcore sweep --once` (ADR 0003: the sweep and migrate tasks are owned by this repository).
# The task definition itself comes from the `workload` module with `create_service = false`.

locals {
  name = "${var.tags["Environment"]}-${var.name}"
}

resource "aws_iam_role" "scheduler" {
  name_prefix          = "${local.name}-sched-"
  permissions_boundary = var.permissions_boundary == "" ? null : var.permissions_boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { Service = ["scheduler.amazonaws.com"] }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "run-${var.name}"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunTask"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = ["${var.task_definition_arn_without_revision}:*"]
        Condition = {
          ArnEquals = { "ecs:cluster" = var.cluster_arn }
        }
      },
      {
        Sid      = "PassTaskRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = var.task_role_arns
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_scheduler_schedule" "this" {
  name                = local.name
  description         = var.description
  schedule_expression = var.schedule_expression
  state               = var.enabled ? "ENABLED" : "DISABLED"

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = var.cluster_arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = var.task_definition_arn_without_revision
      launch_type         = "FARGATE"
      platform_version    = "LATEST"
      propagate_tags      = "TASK_DEFINITION"

      network_configuration {
        subnets          = var.subnet_ids
        security_groups  = var.security_group_ids
        assign_public_ip = false
      }
    }

    retry_policy {
      maximum_retry_attempts       = var.maximum_retry_attempts
      maximum_event_age_in_seconds = 300
    }
  }
}
