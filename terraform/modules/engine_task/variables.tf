variable "enabled" {
  type        = bool
  default     = false
  description = "Declare the engine task. Nothing is planned while false."
}

variable "aws_region" {
  type        = string
  description = "Region for log configuration. No default (docs/aws-asks.md AWS-02)."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags (Environment is used in names)."
}

# --- consumed from shared foundations (built elsewhere; nothing here creates network, SGs, RDS or the bucket) ---

variable "cluster_arn" {
  type        = string
  default     = ""
  description = "ECS cluster ARN from the compute foundation. Required when enabled."
}

variable "subnet_ids" {
  type        = list(string)
  default     = []
  description = "Private subnet ids. Required when enabled."
}

variable "security_group_ids" {
  type        = list(string)
  default     = []
  description = "Security groups from the network foundation. The engine is reachable only from where those groups allow."
}

variable "bucket_name" {
  type        = string
  default     = ""
  description = "Shared data bucket name; the engine uses the artifacts/, evidence/, reports/ and console/ prefixes."
}

variable "bucket_prefixes" {
  type        = list(string)
  default     = ["artifacts", "evidence", "reports", "console"]
  description = "Prefixes of the single shared bucket the task role may read and write."
}

variable "database_endpoint" {
  type        = string
  default     = ""
  description = "RDS Postgres endpoint (host:port) from the data foundation. One database, name below. The schemas (raw, augmented, product, pulso) and roles are created by the engine itself from its db/sql DDL and migrations/ at start (design section 9), not by Terraform."
}

variable "database_name" {
  type    = string
  default = "pulso"
}

variable "db_instance_identifier" {
  type        = string
  default     = ""
  description = "RDS instance identifier for the database alarms. Empty means no database alarms."
}

variable "secret_arns" {
  type        = map(string)
  default     = {}
  description = "Environment variable name to Secrets Manager or SSM parameter ARN (for example PULSO_PG_APP_DSN). Values are never accepted here."

  validation {
    condition     = alltrue([for v in values(var.secret_arns) : can(regex("^arn:aws[a-z-]*:(secretsmanager|ssm):", v))])
    error_message = "secret_arns values must be Secrets Manager or SSM ARNs, never secret values."
  }
}

variable "kms_key_arn" {
  type        = string
  default     = ""
  description = "Optional customer-managed key used by the secrets; adds kms:Decrypt for the execution role."
}

# --- images ---

variable "pulso_image" {
  type        = string
  default     = ""
  description = "pulso image pinned by digest (repo@sha256:<64 hex>), from the release manifest."

  validation {
    condition     = !var.enabled || can(regex("@sha256:[0-9a-f]{64}$", var.pulso_image))
    error_message = "When enabled, pulso_image must be pinned by digest (@sha256:<64 lowercase hex>)."
  }
}

variable "core_runtime_image" {
  type        = string
  default     = ""
  description = "core-runtime sidecar image pinned by digest."

  validation {
    condition     = !var.enabled || can(regex("@sha256:[0-9a-f]{64}$", var.core_runtime_image))
    error_message = "When enabled, core_runtime_image must be pinned by digest (@sha256:<64 lowercase hex>)."
  }
}

# --- sizing and runtime ---

variable "launch_type" {
  type        = string
  default     = "FARGATE"
  description = "FARGATE or EC2 (EC2 may be cheaper at hackathon scale; the cluster must have capacity)."

  validation {
    condition     = contains(["FARGATE", "EC2"], var.launch_type)
    error_message = "launch_type must be FARGATE or EC2."
  }
}

variable "cpu" {
  type    = number
  default = 1024
}

variable "memory" {
  type    = number
  default = 2048
}

variable "pulso_port" {
  type    = number
  default = 8080
}

variable "core_runtime_port" {
  type    = number
  default = 8000
}

variable "desired_count" {
  type        = number
  default     = 0
  description = "Number of engine tasks. 0 until a human raises it."
}

variable "kill_switch" {
  type        = bool
  default     = false
  description = "When true the service is forced to desired_count = 0 whatever desired_count says."
}

variable "environment" {
  type        = map(string)
  default     = {}
  description = "Non-secret configuration (for example PULSO_DATA_MODE, PULSO_SOURCE_ADAPTER). Never put credentials here."
}

variable "permissions_boundary" {
  type    = string
  default = ""
}

# --- observability ---

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "alarm_actions" {
  type        = list(string)
  default     = []
  description = "SNS topic ARNs notified by the alarms."
}
