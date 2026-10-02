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

variable "runtime_database_secret_arn" {
  type        = string
  description = "Externally bootstrapped pulso_runtime secret ARN; never the RDS master secret."

  validation {
    condition = can(regex(
      "^arn:(aws|aws-us-gov|aws-cn):secretsmanager:[^:]+:[0-9]{12}:secret:.+$",
      var.runtime_database_secret_arn,
    ))
    error_message = "runtime_database_secret_arn must be a non-empty Secrets Manager ARN for the application database secret."
  }
}

variable "runtime_database_secret_kms_key_arn" {
  type        = string
  description = "Optional customer-managed KMS key that encrypts the pulso_runtime database secret."
}

variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input; never included in a runtime policy document."
}
