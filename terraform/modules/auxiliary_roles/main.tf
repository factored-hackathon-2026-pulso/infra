# task-sandbox (CLQ-43, disabled by default), the worker launch policy for it, and the
# read-only observability reader. Nothing here is attached to existing roles.

variable "environment_name" {
  type = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.environment_name))
    error_message = "environment_name must be lowercase alphanumerics and hyphens (it is embedded in IAM resource ARNs)."
  }
}
variable "aws_region" { type = string }
variable "source_bucket_arn" { type = string }
variable "artifact_bucket_arn" { type = string }

variable "sandbox_session_prefix" {
  type        = string
  description = "Artifact-bucket prefix the sandbox may read."

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$", var.sandbox_session_prefix))
    error_message = "sandbox_session_prefix must be a concrete key prefix without wildcards, leading or trailing slash."
  }
}

variable "sandbox_results_prefix" {
  type        = string
  description = "Artifact-bucket prefix the sandbox may write."

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$", var.sandbox_results_prefix))
    error_message = "sandbox_results_prefix must be a concrete key prefix without wildcards, leading or trailing slash."
  }
  validation {
    condition = (
      !startswith("${var.sandbox_results_prefix}/", "${var.sandbox_session_prefix}/") &&
      !startswith("${var.sandbox_session_prefix}/", "${var.sandbox_results_prefix}/")
    )
    error_message = "The sandbox read and write prefixes must not overlap (a sandbox must not overwrite its own inputs)."
  }
}

variable "sandbox_task_definition_arn" {
  type        = string
  description = "sandbox-lab task definition ARN (family:* form) the worker may run."
}

variable "sandbox_enabled" {
  type        = bool
  description = "False until the CLQ-43 sandbox contract exists."
}

variable "worker_task_role_name" {
  type        = string
  description = "Engine worker task role the launch policy is meant for (attachment is done by the caller)."
}

variable "observability_reader_principals" {
  type        = list(string)
  description = "Principal ARNs allowed to assume the reader. Empty disables the role."

  validation {
    condition     = alltrue([for p in var.observability_reader_principals : startswith(p, "arn:") && !strcontains(p, "*") && !endswith(p, ":root")])
    error_message = "Reader principals must be specific role or user ARNs: no wildcard and no account root."
  }
}

variable "permissions_boundary" { type = string }
variable "tags" { type = map(string) }

locals {
  boundary = var.permissions_boundary == "" ? null : var.permissions_boundary
  ecs_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { Service = ["ecs-tasks.amazonaws.com"] }
    }]
  })
  sandbox_role_arns = var.sandbox_enabled ? [aws_iam_role.task_sandbox[0].arn, aws_iam_role.sandbox_execution[0].arn] : []
}

resource "aws_iam_role" "task_sandbox" {
  count = var.sandbox_enabled ? 1 : 0

  name_prefix          = "${var.environment_name}-sandbox-task-"
  assume_role_policy   = local.ecs_trust
  permissions_boundary = local.boundary
  tags                 = var.tags
}

# The sandbox pulls its image and writes logs through the managed execution policy only.
resource "aws_iam_role" "sandbox_execution" {
  count = var.sandbox_enabled ? 1 : 0

  name_prefix          = "${var.environment_name}-sandbox-exec-"
  assume_role_policy   = local.ecs_trust
  permissions_boundary = local.boundary
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "sandbox_execution" {
  count = var.sandbox_enabled ? 1 : 0

  role       = aws_iam_role.sandbox_execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "task_sandbox" {
  count = var.sandbox_enabled ? 1 : 0

  name = "sandbox-session-io"
  role = aws_iam_role.task_sandbox[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadSessionPrefix"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = ["${var.artifact_bucket_arn}/${var.sandbox_session_prefix}/*"]
      },
      {
        Sid      = "WriteResultsPrefix"
        Effect   = "Allow"
        Action   = ["s3:PutObject"]
        Resource = ["${var.artifact_bucket_arn}/${var.sandbox_results_prefix}/*"]
      },
      {
        Sid      = "DenySourceBucket"
        Effect   = "Deny"
        Action   = ["s3:*"]
        Resource = [var.source_bucket_arn, "${var.source_bucket_arn}/*"]
      },
      {
        Sid      = "DenyControlPlane"
        Effect   = "Deny"
        Action   = ["secretsmanager:*", "ecs:*", "iam:*"]
        Resource = ["*"]
      },
    ]
  })
}

resource "aws_iam_policy" "worker_sandbox_launch" {
  count = var.sandbox_enabled ? 1 : 0

  name_prefix = "${var.environment_name}-worker-sandbox-launch-"
  description = "Lets ${var.worker_task_role_name} launch sandbox-lab; attach in the caller."
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunSandboxTaskOnly"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = [var.sandbox_task_definition_arn]
      },
      {
        Sid      = "PassSandboxRolesToEcsOnly"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = local.sandbox_role_arns
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
  tags = var.tags
}

resource "aws_iam_role" "observability_reader" {
  count = length(var.observability_reader_principals) == 0 ? 0 : 1

  name_prefix          = "${var.environment_name}-observability-reader-"
  permissions_boundary = local.boundary
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { AWS = var.observability_reader_principals }
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "observability_reader" {
  count = length(var.observability_reader_principals) == 0 ? 0 : 1

  name = "pulso-logs-read-only"
  role = aws_iam_role.observability_reader[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadPulsoLogGroups"
        Effect = "Allow"
        Action = ["logs:GetLogEvents", "logs:FilterLogEvents", "logs:StartQuery"]
        Resource = [
          "arn:aws:logs:${var.aws_region}:*:log-group:/pulso/${var.environment_name}/*",
          "arn:aws:logs:${var.aws_region}:*:log-group:/pulso/${var.environment_name}/*:log-stream:*",
        ]
      },
      {
        # These logs actions do not support resource-level scoping; they expose metadata or results of
        # queries the caller itself started on the log groups above.
        Sid      = "LogsMetadataAndQueryResults"
        Effect   = "Allow"
        Action   = ["logs:DescribeLogGroups", "logs:DescribeLogStreams", "logs:StopQuery", "logs:GetQueryResults"]
        Resource = ["*"]
      },
      {
        Sid      = "ReadAlarmsAndMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:DescribeAlarms", "cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]
        Resource = ["*"]
      },
    ]
  })
}

output "task_sandbox_role_arn" { value = var.sandbox_enabled ? aws_iam_role.task_sandbox[0].arn : null }
output "sandbox_execution_role_arn" { value = var.sandbox_enabled ? aws_iam_role.sandbox_execution[0].arn : null }
output "worker_sandbox_launch_policy_arn" { value = var.sandbox_enabled ? aws_iam_policy.worker_sandbox_launch[0].arn : null }
output "observability_reader_role_arn" { value = length(var.observability_reader_principals) == 0 ? null : aws_iam_role.observability_reader[0].arn }
