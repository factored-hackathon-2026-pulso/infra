variable "name" {
  type        = string
  description = "Schedule name suffix, for example core-sweep."
}

variable "description" {
  type    = string
  default = ""
}

variable "cluster_arn" { type = string }

variable "task_definition_arn_without_revision" {
  type        = string
  description = "Task definition ARN without a revision, so the latest active revision runs."

  validation {
    condition     = can(regex("^arn:aws[a-z-]*:ecs:[a-z0-9-]+:[0-9]{12}:task-definition/[A-Za-z0-9_-]+$", var.task_definition_arn_without_revision))
    error_message = "Pass the task definition ARN without the :revision suffix."
  }
}

variable "task_role_arns" {
  type        = list(string)
  description = "Task and execution role ARNs the scheduler may pass to ECS."

  validation {
    condition     = length(var.task_role_arns) > 0
    error_message = "At least the execution role must be passable."
  }
}

variable "subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }

variable "schedule_expression" {
  type    = string
  default = "rate(5 minutes)"
}

variable "enabled" {
  type    = bool
  default = true
}

variable "maximum_retry_attempts" {
  type    = number
  default = 2
}

variable "permissions_boundary" {
  type    = string
  default = ""
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
