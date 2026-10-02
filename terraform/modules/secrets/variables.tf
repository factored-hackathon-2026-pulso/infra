variable "secret_name_prefix" {
  type        = string
  description = "Environment-scoped prefix for future Secrets Manager metadata; no secret value is stored here."
}

variable "kms_key_arn" {
  type        = string
  description = "Optional customer-managed KMS key ARN selected by a future security slice."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
