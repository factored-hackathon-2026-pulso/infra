variable "name" {
  type        = string
  description = "Workload name; used as family, container and service name."
}

variable "image" {
  type        = string
  description = "Immutable image reference pinned by digest (repo@sha256:<64 hex>)."

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest and match @sha256:<64 lowercase hex>; mutable tags are rejected."
  }
}

variable "command" {
  type        = list(string)
  default     = null
  description = "Optional container command override (for example agentcore migrate)."
}

variable "cluster_arn" { type = string }
variable "subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }
variable "task_role_arn" { type = string }
variable "execution_role_arn" { type = string }
variable "aws_region" { type = string }

variable "log_group_name" {
  type        = string
  description = "CloudWatch log group written by the task; owned by the observability module (single owner, DR-86). Never created here."
}

variable "port" {
  type        = number
  default     = null
  description = "Container port, or null for a task without a listener."
}

variable "cpu" {
  type    = number
  default = 256
}

variable "memory" {
  type    = number
  default = 512
}

variable "desired_count" {
  type    = number
  default = 0

  validation {
    condition     = var.desired_count >= 0
    error_message = "desired_count must not be negative."
  }
}

variable "create_service" {
  type        = bool
  default     = true
  description = "False renders only a task definition (one-off tasks such as migrate or sweep)."
}

variable "environment" {
  type        = map(string)
  default     = {}
  description = "Plain environment variables. AGENTCORE_ALLOW_DEMO is forbidden."

  validation {
    condition     = !contains(keys(var.environment), "AGENTCORE_ALLOW_DEMO")
    error_message = "AGENTCORE_ALLOW_DEMO must never be set in a deployed workload."
  }
}

variable "secrets" {
  type        = map(string)
  default     = {}
  description = "Environment name -> Secrets Manager valueFrom (arn or arn:json-key::). Values live outside Terraform."

  validation {
    condition     = !contains(keys(var.secrets), "AGENTCORE_ALLOW_DEMO")
    error_message = "AGENTCORE_ALLOW_DEMO must never be injected as a secret."
  }
}

variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input; no injected secret may reference it."
}

variable "health_check_command" {
  type        = list(string)
  default     = null
  description = "Container health check command (CMD-SHELL form); null renders no healthCheck."
}

variable "stop_timeout" {
  type    = number
  default = 30

  validation {
    condition     = var.stop_timeout >= 2 && var.stop_timeout <= 120
    error_message = "Fargate stopTimeout must be between 2 and 120 seconds."
  }
}

variable "service_registry_arn" {
  type        = string
  default     = null
  description = "Optional Cloud Map service ARN for private DNS (Core services)."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
