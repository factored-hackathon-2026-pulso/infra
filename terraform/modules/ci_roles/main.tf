# GitHub OIDC roles: ci-plan (read-only), ci-apply and deploy (ECS rollout only).
# Every role has count = 0 until the external account-level OIDC provider ARN and
# exact subjects are approved inputs (DR-83). This module never creates the provider.

variable "github_oidc_provider_arn" {
  type        = string
  description = "Account-level GitHub OIDC provider ARN (external prerequisite). Empty disables every role."
}

variable "plan_subjects" {
  type        = list(string)
  description = "Exact OIDC subjects allowed to assume ci-plan."

  validation {
    condition     = alltrue([for s in var.plan_subjects : can(regex("^repo:[^*?/]+/[^*?/]+:[^*?]+$", s))])
    error_message = "plan_subjects must be exact repo:<owner>/<repo>:<ref|environment|pull_request> values without wildcards."
  }
}

variable "apply_subjects" {
  type        = list(string)
  description = "Exact OIDC subjects allowed to assume ci-apply (use a protected GitHub environment)."

  validation {
    condition     = alltrue([for s in var.apply_subjects : can(regex("^repo:[^*?/]+/[^*?/]+:[^*?]+$", s))])
    error_message = "apply_subjects must be exact repo:<owner>/<repo>:<ref|environment|pull_request> values without wildcards."
  }
}

variable "deploy_subjects" {
  type        = list(string)
  description = "Exact OIDC subjects allowed to assume the ECS deploy role."

  validation {
    condition     = alltrue([for s in var.deploy_subjects : can(regex("^repo:[^*?/]+/[^*?/]+:[^*?]+$", s))])
    error_message = "deploy_subjects must be exact repo:<owner>/<repo>:<ref|environment|pull_request> values without wildcards."
  }
}

variable "apply_policy_json" {
  type        = string
  description = "Approved ci-apply policy document (external input). Required when apply is enabled."
}

variable "permissions_boundary" {
  type        = string
  description = "Permissions boundary ARN. Required for ci-apply and deploy."
}

variable "deploy_cluster_arn" { type = string }
variable "deploy_service_arns" { type = list(string) }
variable "deploy_task_definition_arns" { type = list(string) }

variable "passable_role_arns" {
  type        = list(string)
  description = "Task and execution role ARNs the deploy role may pass to ECS; nothing else."
}

variable "tags" { type = map(string) }

locals {
  oidc_host = "token.actions.githubusercontent.com"
  has_oidc  = var.github_oidc_provider_arn != ""
  plan_on   = local.has_oidc && length(var.plan_subjects) > 0
  apply_on  = local.has_oidc && length(var.apply_subjects) > 0
  deploy_on = local.has_oidc && length(var.deploy_subjects) > 0
  boundary  = var.permissions_boundary == "" ? null : var.permissions_boundary

  trust = { for k, subjects in {
    plan   = var.plan_subjects
    apply  = var.apply_subjects
    deploy = var.deploy_subjects
    } : k => jsonencode({
      Version = "2012-10-17"
      Statement = [{
        Effect    = "Allow"
        Action    = ["sts:AssumeRoleWithWebIdentity"]
        Principal = { Federated = var.github_oidc_provider_arn }
        Condition = {
          StringEquals = {
            "${local.oidc_host}:aud" = "sts.amazonaws.com"
            "${local.oidc_host}:sub" = subjects
          }
        }
      }]
  }) }

  deploy_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RolloutServices"
        Effect   = "Allow"
        Action   = ["ecs:UpdateService", "ecs:DescribeServices"]
        Resource = var.deploy_service_arns
      },
      {
        Sid      = "RunOneOffTasks"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = var.deploy_task_definition_arns
        Condition = {
          ArnEquals = { "ecs:cluster" = var.deploy_cluster_arn }
        }
      },
      {
        Sid      = "PassTaskAndExecutionRolesToEcsOnly"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = var.passable_role_arns
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  }
}

resource "aws_iam_role" "ci_plan" {
  count = local.plan_on ? 1 : 0

  name_prefix        = "${var.tags["Environment"]}-ci-plan-"
  assume_role_policy = local.trust["plan"]
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ci_plan_read_only" {
  count = local.plan_on ? 1 : 0

  role       = aws_iam_role.ci_plan[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role" "ci_apply" {
  count = local.apply_on ? 1 : 0

  name_prefix          = "${var.tags["Environment"]}-ci-apply-"
  assume_role_policy   = local.trust["apply"]
  permissions_boundary = local.boundary
  tags                 = var.tags

  lifecycle {
    precondition {
      condition     = var.permissions_boundary != "" && var.apply_policy_json != ""
      error_message = "ci-apply needs the approved permissions boundary and the approved apply policy."
    }
  }
}

resource "aws_iam_role_policy" "ci_apply" {
  count = local.apply_on ? 1 : 0

  name   = "approved-apply-policy"
  role   = aws_iam_role.ci_apply[0].id
  policy = var.apply_policy_json
}

resource "aws_iam_role" "deploy" {
  count = local.deploy_on ? 1 : 0

  name_prefix          = "${var.tags["Environment"]}-deploy-"
  assume_role_policy   = local.trust["deploy"]
  permissions_boundary = local.boundary
  tags                 = var.tags

  lifecycle {
    precondition {
      condition     = var.permissions_boundary != ""
      error_message = "The deploy role needs the approved permissions boundary."
    }
  }
}

resource "aws_iam_role_policy" "deploy" {
  count = local.deploy_on ? 1 : 0

  name   = "ecs-rollout"
  role   = aws_iam_role.deploy[0].id
  policy = jsonencode(local.deploy_policy)
}

output "ci_plan_role_arn" { value = local.plan_on ? aws_iam_role.ci_plan[0].arn : null }
output "ci_apply_role_arn" { value = local.apply_on ? aws_iam_role.ci_apply[0].arn : null }
output "deploy_role_arn" { value = local.deploy_on ? aws_iam_role.deploy[0].arn : null }
