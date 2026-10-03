variable "aws_region" { type = string }

variable "image" {
  type        = string
  description = "Immutable Agent Core image reference by digest (repository@sha256:...). Never a tag (ADR 0003)."

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9./_-]*@sha256:[a-f0-9]{64}$", var.image))
    error_message = "image must be pinned by digest: repository@sha256:<64 hex>."
  }
}

variable "cluster_arn" { type = string }
variable "cluster_name" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }

variable "target_group_arn" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "load_balancer_arn_suffix" { type = string }

variable "container_port" {
  type    = number
  default = 8000
}

variable "cpu_architecture" {
  type        = string
  description = "Must match the architecture the image was built for."
  default     = "X86_64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

# --- Data plane --------------------------------------------------------------------------------------------

variable "blob_bucket_name" { type = string }
variable "blob_bucket_arn" { type = string }

variable "blob_kms_key_arn" {
  type        = string
  description = "Customer-managed key of the blob bucket; empty when the bucket uses AES256."
  default     = ""
}

variable "events_topic_arn" { type = string }

variable "secrets_kms_key_arn" {
  type        = string
  description = "Customer-managed key that encrypts the secret entries; empty selects the AWS-managed key."
  default     = ""
}

variable "secret_name_prefix" {
  type        = string
  description = "Environment-scoped prefix for the Agent Core secret entries."
}

variable "extra_secret_names" {
  type        = list(string)
  description = "Additional environment variables delivered as secrets, for example one per LLM endpoint key."
  default     = []

  validation {
    condition     = alltrue([for n in var.extra_secret_names : can(regex("^[A-Z][A-Z0-9_]*$", n))])
    error_message = "Secret names are environment variable names: upper-case letters, digits and underscores."
  }
}

variable "permissions_boundary" {
  type    = string
  default = ""
}

# --- Behaviour ---------------------------------------------------------------------------------------------

variable "serve_command" {
  type        = list(string)
  description = "Arguments of `agentcore` for the API. Outside demo mode the real pieces are passed here (ADR 0003)."
  default     = ["serve", "--host", "0.0.0.0", "--port", "8000"]
}

variable "serve_agents" {
  type        = string
  description = "AGENTCORE_SERVE_AGENTS: comma-separated agents whose prod release is checked at startup."
  default     = ""
}

variable "allow_demo" {
  type        = bool
  description = "Sets AGENTCORE_ALLOW_DEMO=1. Allowed only in the hackathon prod demo, with synthetic data."
  default     = false
}

variable "otel_environment" {
  type        = map(string)
  description = "Standard OTEL_* variables, for example OTEL_EXPORTER_OTLP_ENDPOINT."
  default     = {}
}

variable "db_pool_max" {
  type        = number
  description = "AGENTCORE_DB_POOL_MAX per task. Tasks x pool x 2 pools must stay under the proxy limit."
  default     = 10
}

variable "log_retention_days" { type = number }

# --- Capacity ----------------------------------------------------------------------------------------------

variable "serve_cpu" {
  type    = number
  default = 512
}

variable "serve_memory" {
  type    = number
  default = 1024
}

variable "serve_desired_count" {
  type        = number
  description = "Initial count; Application Auto Scaling owns it afterwards. 0 declares the service without tasks."
  default     = 0
}

variable "serve_min_count" {
  type    = number
  default = 0
}

variable "serve_max_count" {
  type    = number
  default = 4
}

variable "relay_desired_count" {
  type        = number
  description = "Relay tasks. More than one is safe (advisory lock) and only adds a warm standby."
  default     = 1
}

variable "cpu_target_percent" {
  type    = number
  default = 60
}

variable "requests_per_target" {
  type    = number
  default = 200
}

variable "sweep_schedule" {
  type    = string
  default = "rate(5 minutes)"
}

variable "sweep_enabled" {
  type    = bool
  default = true
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
