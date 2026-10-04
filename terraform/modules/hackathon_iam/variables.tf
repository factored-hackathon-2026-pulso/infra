variable "name" {
  type        = string
  description = "Name prefix for roles, profiles and policies; also the log-group prefix (/<name>/*)."
}

variable "region" {
  type        = string
  description = "AWS region used in SSM and CloudWatch Logs ARNs."
}

variable "ssm_parameter_path_prefix" {
  type        = string
  description = "Root SSM Parameter Store path, leading slash and no trailing slash, for example /hk. Each workload reads only <root>/<workload>/*."

  validation {
    condition     = startswith(var.ssm_parameter_path_prefix, "/") && !endswith(var.ssm_parameter_path_prefix, "/")
    error_message = "Use a leading slash and no trailing slash."
  }
}

variable "s3_bucket_name" {
  type        = string
  description = "The single data bucket the hosts may use."
}

variable "core_s3_prefixes" {
  type        = list(string)
  description = "Key prefixes (no slashes at the ends) core may read and write, for example core/blobs."
  default     = ["core/blobs"]
}

variable "engine_s3_prefixes" {
  type        = list(string)
  description = "Key prefixes the engine may read and write."
  default     = ["engine"]
}

variable "engine_lake_read_prefixes" {
  type        = list(string)
  description = "Read-only prefixes for the engine's loader (landing zone and lake)."
  default     = ["landing", "lake"]
}

variable "ecr_repository_arns_core" {
  type        = list(string)
  description = "ECR repositories the core host (core and llm-gateway images) may pull."
  default     = []
}

variable "ecr_repository_arns_platform" {
  type        = list(string)
  description = "ECR repositories the platform host may pull."
  default     = []
}

variable "ecr_repository_arns_engine" {
  type        = list(string)
  description = "ECR repositories the engine host may pull."
  default     = []
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource."
}

variable "secret_arn" {
  type        = string
  description = "ARN of the one Secrets Manager secret every host reads (the host role gets GetSecretValue on exactly this ARN)."
}

variable "kms_key_arn" {
  type        = string
  description = "Data KMS key: objects in the bucket are SSE-KMS, so the hosts need kms:Decrypt/GenerateDataKey on it."
}

variable "bundle_prefix" {
  type        = string
  description = "Key prefix (no slashes at the ends) where compose bundles are published; each host reads <prefix>/<workload>/*."
  default     = "engine/deploy"
}

variable "engine_can_load" {
  type        = bool
  description = "Let the engine host run the data loader: read landing/ and lake/ and write lake/ (the loader policy). Core and platform never get this."
  default     = false
}

variable "enable_host_builder" {
  type        = bool
  description = "free_plan fallback: the core host builds images itself (scripts/aws-prod.ps1 images -Builder host). Grants the CORE role ECR push on ecr_push_repository_arns, read of engine/build-src/ and write of engine/build-out/."
  default     = false
}

variable "ecr_push_repository_arns" {
  type        = list(string)
  description = "ECR repositories the core host may push to when enable_host_builder is true."
  default     = []
}
