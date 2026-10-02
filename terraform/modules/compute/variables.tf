variable "image_digest" {
  type        = string
  description = "Approved immutable engine image digest consumed by deployment."
}

variable "compute_engine" {
  type        = string
  description = "Deferred runtime choice (for example ECS or EC2); this foundation does not select or deploy one."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs where runtime compute may be scheduled."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Least-privilege security group IDs attached to compute."
}
variable "task_role_arn" { type = string }
variable "execution_role_arn" { type = string }
variable "log_group_name" { type = string }
variable "aws_region" { type = string }
variable "desired_count" { type = number }

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
