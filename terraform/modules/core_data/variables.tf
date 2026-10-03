variable "name_prefix" {
  type        = string
  description = "Prefix for the topic and queues, for example staging-agent-core."
}

variable "blob_bucket_name" {
  type        = string
  description = "Globally unique name of the registry blob bucket."
}

variable "kms_key_arn" {
  type        = string
  description = "Optional customer-managed KMS key for the blob bucket; empty selects AES256 (SSE-S3). A key requires a key policy that lets the Core task role use it, because task roles hold no kms: permissions (ADR 0003)."
  default     = ""
}

variable "sns_kms_key_id" {
  type        = string
  description = "Optional KMS key for the events topic. Null leaves the topic unencrypted at rest: the outbound events carry no PII (agent-core ADR 0008) and a workload task role may not hold kms: permissions (ADR 0003), so a key needs a key policy that names the publisher."
  default     = null
}

variable "blob_admin_principal_arns" {
  type        = list(string)
  description = "Break-glass principals allowed to delete blobs. Empty denies deletion to everyone."
  default     = []
}

variable "noncurrent_version_days" {
  type    = number
  default = 90
}

variable "consumers" {
  type = map(object({
    event_types                = list(string)
    max_receive_count          = optional(number, 5)
    visibility_timeout_seconds = optional(number, 60)
  }))
  description = "Queue per consumer, filtered by outbound event_type (empty list = every type)."
  default     = {}

  validation {
    condition     = alltrue([for name in keys(var.consumers) : can(regex("^[a-z0-9-]{1,40}$", name))])
    error_message = "Consumer names must be 1-40 lowercase letters, digits or hyphens."
  }
}

variable "queue_retention_seconds" {
  type    = number
  default = 345600 # 4 days
}

variable "max_message_age_seconds" {
  type        = number
  description = "Alarm threshold for the oldest message in a consumer queue."
  default     = 900
}

variable "alarm_actions" { type = list(string) }

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
