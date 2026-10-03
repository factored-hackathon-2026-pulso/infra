variable "workload_name" {
  type        = string
  description = "Workload these roles belong to (for example pulso-core-runtime)."
}

variable "aws_region" { type = string }

variable "own_secret_arns" {
  type        = list(string)
  description = "Secrets Manager ARNs this workload's execution role may resolve; nothing else is readable."
}

variable "secret_kms_key_arns" {
  type        = list(string)
  description = "Customer-managed keys encrypting those secrets; empty selects the AWS-managed-key path."
}

variable "task_statements" {
  type        = list(any)
  description = "Explicit IAM statements for the task role. Empty (default): the task has no AWS permissions."
}

variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input; never granted to any role (T-07)."
}

variable "permissions_boundary" {
  type        = string
  description = "Permissions boundary ARN; empty means none."
}

variable "tags" { type = map(string) }

locals {
  assume_policy = {
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { Service = ["ecs-tasks.amazonaws.com"] }
    }]
  }
  boundary = var.permissions_boundary == "" ? null : var.permissions_boundary

  execution_secret_policy = {
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ReadOwnSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = var.own_secret_arns
      }],
      length(var.secret_kms_key_arns) == 0 ? [] : [{
        Sid      = "DecryptOwnSecrets"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.secret_kms_key_arns
        Condition = {
          StringEquals = { "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com" }
          StringLike   = { "kms:EncryptionContext:SecretARN" = var.own_secret_arns }
        }
      }],
    )
  }
}

resource "aws_iam_role" "task" {
  name_prefix          = "${var.tags["Environment"]}-${var.workload_name}-task-"
  assume_role_policy   = jsonencode(local.assume_policy)
  permissions_boundary = local.boundary
  tags                 = var.tags
}

resource "aws_iam_role" "execution" {
  name_prefix          = "${var.tags["Environment"]}-${var.workload_name}-exec-"
  assume_role_policy   = jsonencode(local.assume_policy)
  permissions_boundary = local.boundary
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS resolves task-definition secret references with the execution role.
resource "aws_iam_role_policy" "execution_secrets" {
  name   = "${var.workload_name}-own-secrets"
  role   = aws_iam_role.execution.id
  policy = jsonencode(local.execution_secret_policy)

  lifecycle {
    precondition {
      condition = alltrue([
        for arn in var.own_secret_arns : !startswith(arn, var.rds_master_secret_arn_guard)
      ])
      error_message = "A workload execution role must never be granted the RDS master secret."
    }
  }
}

resource "aws_iam_role_policy" "task" {
  count = length(var.task_statements) == 0 ? 0 : 1

  name = "${var.workload_name}-task"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = var.task_statements
  })

  lifecycle {
    precondition {
      condition     = !strcontains(jsonencode(var.task_statements), var.rds_master_secret_arn_guard)
      error_message = "A workload task role must never reference the RDS master secret."
    }
  }
}

output "task_role_arn" { value = aws_iam_role.task.arn }
output "execution_role_arn" { value = aws_iam_role.execution.arn }
