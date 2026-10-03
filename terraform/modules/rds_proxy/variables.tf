variable "aws_region" { type = string }

variable "db_instance_identifier" {
  type        = string
  description = "Identifier of the RDS instance the proxy fronts."
}

variable "private_subnet_ids" { type = list(string) }
variable "security_group_ids" { type = list(string) }

variable "application_secret_arn" {
  type        = string
  description = "Externally bootstrapped application-role secret; never the RDS master secret."

  validation {
    condition = can(regex(
      "^arn:(aws|aws-us-gov|aws-cn):secretsmanager:[^:]+:[0-9]{12}:secret:.+$",
      var.application_secret_arn,
    ))
    error_message = "application_secret_arn must be a Secrets Manager ARN."
  }
}

variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input; never included in the proxy role policy."
}

variable "secret_kms_key_arn" {
  type        = string
  description = "Customer-managed KMS key that encrypts the application secret; empty selects the AWS-managed key."
  default     = ""
}

variable "idle_client_timeout_seconds" {
  type    = number
  default = 1800
}

variable "max_connections_percent" {
  type        = number
  description = "Share of the instance max_connections the proxy may use."
  default     = 90
}

variable "max_idle_connections_percent" {
  type    = number
  default = 50
}

variable "connection_borrow_timeout_seconds" {
  type    = number
  default = 30
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
