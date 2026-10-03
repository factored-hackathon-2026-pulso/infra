variable "image_digest" {
  type        = string
  description = "Approved immutable engine image digest consumed by deployment."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs where runtime compute may be scheduled."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Least-privilege security group IDs attached to compute."
}

variable "database_endpoint" { type = string }

variable "runtime_database_secret_arn" {
  type = string

  validation {
    condition = can(regex(
      "^arn:(aws|aws-us-gov|aws-cn):secretsmanager:[^:]+:[0-9]{12}:secret:.+$",
      var.runtime_database_secret_arn,
    ))
    error_message = "runtime_database_secret_arn must be a non-empty Secrets Manager ARN for the application database secret."
  }
}

variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input; never propagated to ECS task configuration or IAM."
}
variable "task_role_arn" { type = string }
variable "execution_role_arn" { type = string }
variable "aws_region" { type = string }
variable "desired_count" { type = number }
variable "runtime_secret_arn" { type = string }
variable "log_group_name" {
  type        = string
  description = "CloudWatch log group written by the task; owned by the observability module (single owner, DR-86)."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
