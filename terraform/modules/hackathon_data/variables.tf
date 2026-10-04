variable "name_prefix" {
  description = "Prefix for every resource name, for example pulso-hackathon."
  type        = string
}

variable "region" {
  description = "AWS region, used only to build ARNs for the SSM prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC id. Accepted for the interface contract; the database is placed by db_subnet_ids and sg_db_id."
  type        = string
}

variable "db_subnet_ids" {
  description = "Isolated database subnets (at least two AZs are required by RDS even for a single-AZ instance)."
  type        = list(string)
  default     = []
}

variable "sg_db_id" {
  description = "Security group of the database (ingress from the host only; owned by the network module). Null in container mode."
  type        = string
  default     = null
}

variable "database_mode" {
  description = "rds (RDS PostgreSQL 16 in isolated subnets) or container (Postgres container on the core host, free_plan profile; no RDS resources)."
  type        = string
  default     = "rds"

  validation {
    condition     = contains(["rds", "container"], var.database_mode)
    error_message = "database_mode must be rds or container."
  }
}

variable "db_instance_class" {
  description = "db.t4g.micro (cheapest, ARM) or db.t3.micro."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "db_backup_retention_days" {
  description = "7 by default; 1 is the cheapest. 0 disables backups and is not allowed."
  type        = number
  default     = 7
  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "Backups must stay enabled (1 to 35 days)."
  }
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "db_skip_final_snapshot" {
  description = "Set true only to tear a throwaway hackathon stack down without a final snapshot."
  type        = bool
  default     = false
}

variable "db_max_connections" {
  type    = number
  default = 40
}

variable "enable_redis" {
  description = "Reserved toggle for an optional cache. Off by default; ElastiCache is NOT free-tier (cache.t4g.micro is roughly 12 USD per month). Not implemented in this module."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}

variable "loader_role_arns" {
  description = "Roles allowed to read landing/ and lake/bronze/ (PII in the clear): the data loader/pipeline task."
  type        = list(string)
  default     = []
}

variable "uploader_principal_arns" {
  description = "Principals (the human uploading E0 and CSV/Parquet) allowed to PUT into landing/. Never read."
  type        = list(string)
  default     = []
}

variable "break_glass_principal_arns" {
  description = "Principals exempt from the landing/ VPC-endpoint restriction and the PII deny. Keep to the account admin role."
  type        = list(string)
  default     = []
}

variable "host_role_arns" {
  description = "Roles of the host (compute) allowed to read lake/gold_masked, lake/gold_analytics and engine/*, and use core/, engine/, tmp/."
  type        = list(string)
  default     = []
}

variable "s3_vpc_endpoint_id" {
  description = "S3 gateway endpoint id. When set, reads of landing/ are denied from anywhere else (except break-glass). Empty disables the statement."
  type        = string
  default     = ""
}

variable "bronze_glacier_ir_days" {
  description = "Transition lake/bronze/ to Glacier Instant Retrieval after N days. 0 disables."
  type        = number
  default     = 0
}

variable "enable_eventbridge" {
  type    = bool
  default = false
}

variable "gateway_consumers" {
  description = "Consumer names for GATEWAY_TOKEN_<CONSUMER> keys (names only)."
  type        = list(string)
  default     = ["AGENT_CORE", "ENGINE", "SUPPORT_PLATFORM"]
}

variable "llm_provider_key_names" {
  description = "Provider API key names stored in the secret (ASSUMED defaults; confirm with llm-gateway)."
  type        = list(string)
  default     = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GOOGLE_API_KEY"]
}

variable "bridge_signer_names" {
  description = "Names of the PULSO_BRIDGE_*_SIGNER keys (ASSUMED defaults; confirm with agent-core)."
  type        = list(string)
  default     = ["PULSO_BRIDGE_CONTROL_SIGNER", "PULSO_BRIDGE_LAB_SIGNER"]
}
