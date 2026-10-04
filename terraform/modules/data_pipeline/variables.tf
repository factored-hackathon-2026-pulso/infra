variable "image" {
  type        = string
  description = "data-pipeline image pinned by digest (repo@sha256:<64 hex>). Checked again by the workload module."

  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.image))
    error_message = "image must be pinned by digest; mutable tags are rejected."
  }
}

variable "cluster_arn" { type = string }
variable "subnet_ids" { type = list(string) }

variable "security_group_ids" {
  type        = list(string)
  description = "Security group(s) of the task. The task has no inbound path; it needs egress to the lake and Secrets Manager (private endpoints) and, for the challenge dataset, the controlled path of ADR 0006."
}

variable "aws_region" {
  type        = string
  description = "Region of the lake and of the task (AWS_DEFAULT_REGION). The challenge dataset has its own region: dataset_region."
}

variable "log_group_name" {
  type        = string
  description = "CloudWatch log group written by the task; owned by the observability module. Never created here."
}

variable "cpu" {
  type        = number
  description = "Fargate vCPU units. No default: CPU and memory are not measured on Fargate yet (ADR 0006), so the caller must choose and own the number."
}

variable "memory" {
  type        = number
  description = "Fargate memory in MiB. No default, see cpu."
}

variable "command" {
  type        = list(string)
  default     = null
  description = "Optional arguments appended to the image entrypoint (python -m pipeline.run), for example [\"--steps\", \"ingest_bank,build,publish\"]. Null runs the image default."
}

# --- Lake ---------------------------------------------------------------------------------------------------

variable "lake_bucket_name" {
  type        = string
  description = "Globally unique name of the lake bucket (see the data_lake module)."
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "Optional customer-managed key of the lake. Empty selects SSE-S3. A key needs a key policy that names the roles of this workload and of the readers, because their statements hold no kms: actions."
}

variable "restricted_reader_role_arns" {
  type        = list(string)
  default     = []
  description = "Roles that may read gold_restricted.duckdb (Agent Core runtime). Empty denies everyone."
}

variable "masked_reader_role_arns" {
  type    = list(string)
  default = []
}

variable "analytics_reader_role_arns" {
  type    = list(string)
  default = []
}

variable "evaluator_role_arns" {
  type    = list(string)
  default = []
}

variable "admin_principal_arns" {
  type    = list(string)
  default = []
}

variable "publish_retention_days" {
  type        = number
  default     = null
  description = "Null keeps every publication: retention is a data-owner decision (ADR 0006)."
}

# --- Challenge dataset ----------------------------------------------------------------------------------------

variable "dataset_bucket" {
  type        = string
  description = "Bucket of the challenge dataset, in another account."
}

variable "dataset_prefix" {
  type    = string
  default = "data/"
}

variable "dataset_region" {
  type        = string
  default     = "us-east-2"
  description = "Region of the challenge dataset. It differs from the lake's region, which is why the pipeline keeps both."
}

# --- Secrets (values live outside Terraform) --------------------------------------------------------------------

variable "pseudonym_key_secret_arn" {
  type        = string
  description = "Secrets Manager secret holding the pseudonym HMAC key as a plain string."
}

variable "dataset_reader_secret_arn" {
  type        = string
  description = "Secrets Manager secret holding the organisers' read-only credentials as JSON with the keys access_key_id and secret_access_key. They are injected as DATASET_AWS_*, never as AWS_*: AWS_* outranks the task role and the pipeline would write to the lake with another account's read-only keys."
}

variable "secret_kms_key_arns" {
  type    = list(string)
  default = []
}

variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input; no role and no injected secret may reference it."
}

variable "permissions_boundary" {
  type    = string
  default = ""
}

# --- Schedule ----------------------------------------------------------------------------------------------------

variable "schedule_expression" {
  type        = string
  default     = null
  description = "EventBridge Scheduler expression, for example cron(0 6 * * ? *). Null creates no schedule: the task runs only when started by hand (ecs run-task)."
}

variable "schedule_enabled" {
  type    = bool
  default = false
}

variable "tags" {
  type = map(string)
}
