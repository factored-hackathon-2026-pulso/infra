variable "least_privilege_policy_boundary" {
  type        = string
  description = "Versioned policy-boundary reference or JSON digest for future IAM role/policy creation."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
variable "artifact_bucket_arn" { type = string }
variable "source_bucket_arn" { type = string }
variable "runtime_secret_arn" { type = string }
variable "aws_region" {
  type        = string
  description = "AWS region used to bind optional KMS decrypts to Secrets Manager."
}
variable "runtime_secret_kms_key_arn" {
  type        = string
  description = "Optional customer-managed KMS key that encrypts the runtime secret; empty selects the AWS-managed-key path."
}
