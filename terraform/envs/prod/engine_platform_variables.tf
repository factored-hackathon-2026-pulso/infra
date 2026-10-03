variable "private_endpoints_enabled" {
  type        = bool
  default     = false
  description = "Declare the shared AWS-API VPC endpoints (ECR, Secrets Manager, Logs, KMS, S3 gateway). Billed per AZ-hour."
}

variable "engine_platform_enabled" {
  type        = bool
  default     = false
  description = "Declare the engine platform workloads (control-api, worker, migrate, sandbox-lab). Nothing is planned while false."
}

variable "engine_platform_image" {
  type        = string
  default     = ""
  description = "Engine image digest (repo@sha256:<64 hex>) for control-api, worker and migrate."
}

variable "engine_platform_sandbox_image" {
  type        = string
  default     = ""
  description = "Sandbox-lab image digest."
}

variable "engine_platform_core_runtime_url" {
  type    = string
  default = ""
}

variable "engine_platform_core_runtime_security_group_ids" {
  type    = list(string)
  default = []
}

variable "engine_platform_core_callback_security_group_ids" {
  type    = list(string)
  default = []
}

variable "engine_platform_service_discovery_namespace_id" {
  type    = string
  default = ""
}

variable "engine_ecr_enabled" {
  type        = bool
  default     = false
  description = "Declare the engine and sandbox-lab ECR repositories (reuses the shared ecr module). Needed before the first image push."
}
