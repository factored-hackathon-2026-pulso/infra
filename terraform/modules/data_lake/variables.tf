variable "bucket_name" {
  type        = string
  description = "Globally unique name of the lake bucket (ADR 0006)."
}

variable "kms_key_arn" {
  type        = string
  description = "Optional customer-managed KMS key for the lake bucket; empty selects AES256 (SSE-S3). A key needs a key policy that names every role below, because the statements this module outputs hold no kms: actions (ADR 0003: task roles hold no kms: permissions)."
  default     = ""
}

variable "pipeline_task_role_arns" {
  type        = list(string)
  description = "The data-pipeline task role(s): the only principals that may read bronze/. Empty denies everyone (fail closed)."
  default     = []

  validation {
    condition     = alltrue([for a in var.pipeline_task_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[^*?]+$", a))])
    error_message = "Role ARNs must be concrete (no wildcards)."
  }
}

variable "restricted_reader_role_arns" {
  type        = list(string)
  description = "Roles that may read gold_restricted.duckdb (personal data in clear): the Agent Core runtime read-model tools. Empty denies everyone."
  default     = []

  validation {
    condition     = alltrue([for a in var.restricted_reader_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[^*?]+$", a))])
    error_message = "Role ARNs must be concrete (no wildcards)."
  }
}

variable "masked_reader_role_arns" {
  type        = list(string)
  description = "Roles that may read gold_masked.duckdb (masked personal data). Empty denies everyone."
  default     = []

  validation {
    condition     = alltrue([for a in var.masked_reader_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[^*?]+$", a))])
    error_message = "Role ARNs must be concrete (no wildcards)."
  }
}

variable "analytics_reader_role_arns" {
  type        = list(string)
  description = "Roles that may read gold_analytics.duckdb and its parquet (pseudonymised, no direct identifiers, no labels)."
  default     = []

  validation {
    condition     = alltrue([for a in var.analytics_reader_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[^*?]+$", a))])
    error_message = "Role ARNs must be concrete (no wildcards)."
  }
}

variable "evaluator_role_arns" {
  type        = list(string)
  description = "Roles that may read bronze_eval/ (labels and timeline: the evaluator's answers). Nothing else may."
  default     = []

  validation {
    condition     = alltrue([for a in var.evaluator_role_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/[^*?]+$", a))])
    error_message = "Role ARNs must be concrete (no wildcards)."
  }
}

variable "admin_principal_arns" {
  type        = list(string)
  description = "Break-glass principals allowed to delete objects. Empty denies deletion to everyone; lifecycle rules still apply."
  default     = []
}

variable "publish_retention_days" {
  type        = number
  description = "Days after which old publish/run-* objects expire. Null (default) keeps them: the retention period is a data-owner decision (ADR 0006), not taken here. publish/latest.json is never matched."
  default     = null

  validation {
    condition     = var.publish_retention_days == null || try(var.publish_retention_days >= 7, false)
    error_message = "publish_retention_days must be null or at least 7."
  }
}

variable "noncurrent_version_days" {
  type    = number
  default = 90
}

variable "tags" {
  type = map(string)
}
