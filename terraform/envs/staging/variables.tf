variable "aws_region" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "availability_zones" { type = list(string) }
variable "nat_strategy" { type = string }
variable "least_privilege_policy_boundary" { type = string }
variable "image_digest" { type = string }
variable "artifact_bucket_name" { type = string }
variable "source_bucket_name" { type = string }
variable "database_engine" { type = string }
variable "secret_name_prefix" { type = string }
variable "kms_key_arn" { type = string }
variable "runtime_database_secret_arn" {
  type        = string
  description = "Externally bootstrapped application-role secret ARN; never the RDS master secret."
}
variable "desired_count" { type = number }
variable "database_instance_class" { type = string }
variable "database_backup_retention_days" { type = number }
variable "database_deletion_protection" { type = bool }
variable "database_skip_final_snapshot" { type = bool }
variable "database_multi_az" { type = bool }
variable "log_retention_days" { type = number }
variable "alarm_actions" { type = list(string) }


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
