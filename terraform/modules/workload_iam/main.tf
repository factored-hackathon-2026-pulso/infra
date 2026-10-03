variable "workload_name" {
  type        = string
  description = "Workload these roles belong to (for example pulso-core-runtime)."
}

variable "aws_region" { type = string }

variable "own_secret_arns" {
  type        = list(string)
  description = "Secrets Manager ARNs this workload's execution role may resolve; nothing else is readable."

  validation {
    condition = alltrue([
      for arn in var.own_secret_arns :
      can(regex("^arn:aws[a-z-]*:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[^*?]+(-\\*)?$", arn))
    ])
    error_message = "own_secret_arns must be concrete Secrets Manager ARNs; the only wildcard allowed is the trailing random-suffix -*."
  }
}

variable "secret_kms_key_arns" {
  type        = list(string)
  description = "Customer-managed keys encrypting those secrets; empty selects the AWS-managed-key path."

  validation {
    condition     = alltrue([for arn in var.secret_kms_key_arns : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[^*?]+$", arn))])
    error_message = "secret_kms_key_arns must be concrete KMS key ARNs without wildcards."
  }
}

variable "task_statements" {
  type        = list(any)
  description = "Explicit IAM statements for the task role. Empty (default): the task has no AWS permissions."

  validation {
    # The task role never escalates (iam/sts), never reads secrets directly (the execution role injects them),
    # and never uses a global wildcard action. Deny statements are always allowed.
    condition = alltrue([
      for s in var.task_statements :
      try(s.Effect, "") == "Deny" || (
        !contains([for a in(try(tolist(s.Action), [s.Action])) : can(regex("^(\\*|[a-z0-9-]+:\\*|iam:|sts:|secretsmanager:|kms:)", lower(a)))], true)
        && !can(s.NotAction)
      )
    ])
    error_message = "task_statements must not allow *, service-wide wildcards, iam:, sts:, secretsmanager: or kms: actions, or use NotAction."
  }
}

variable "pass_role_arns" {
  type        = list(string)
  default     = []
  description = "Exact role ARNs this task role may pass to ECS tasks (for example a worker that launches a sandbox task). iam: stays forbidden in task_statements; this is the only, constrained path."

  validation {
    condition     = alltrue([for a in var.pass_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[^*?]+$", a))])
    error_message = "pass_role_arns must be concrete role ARNs without wildcards."
  }
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
      # Confused-deputy guard recommended by AWS for ECS task roles.
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*" }
      }
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

data "aws_caller_identity" "current" {}

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

resource "aws_iam_role_policy" "pass_role" {
  count = length(var.pass_role_arns) == 0 ? 0 : 1

  name = "${var.workload_name}-pass-role"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PassOnlyNamedRolesToEcsTasks"
      Effect    = "Allow"
      Action    = ["iam:PassRole"]
      Resource  = var.pass_role_arns
      Condition = { StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" } }
    }]
  })
}

output "task_role_arn" { value = aws_iam_role.task.arn }
output "execution_role_arn" { value = aws_iam_role.execution.arn }
