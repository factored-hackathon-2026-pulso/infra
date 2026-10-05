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
  description = "Consumer names for GATEWAY_TOKEN_<CONSUMER> keys; a token is generated for each. AGENT_CORE and ENGINE are required (they feed CORE__AGENTCORE_LLM_GATEWAY_TOKEN and PULSO__PULSO_LLM_GATEWAY_TOKEN)."
  type        = list(string)
  default     = ["AGENT_CORE", "ENGINE", "SUPPORT_PLATFORM"]

  validation {
    condition     = contains(var.gateway_consumers, "AGENT_CORE") && contains(var.gateway_consumers, "ENGINE")
    error_message = "gateway_consumers must include AGENT_CORE and ENGINE."
  }
}

variable "llm_provider_key_names" {
  description = "Provider API key names stored in the secret (ASSUMED defaults; confirm with llm-gateway)."
  type        = list(string)
  default     = ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "GOOGLE_API_KEY", "OPENROUTER_API_KEY"]
}

variable "bridge_signer_names" {
  description = "Extra CORE__<NAME> placeholder keys. Empty by default: the shared Core is agent-core's own `agentcore serve` (ADR 0009), which has no PULSO_BRIDGE_* signers."
  type        = list(string)
  default     = []
}

variable "agent_keys_suffix" {
  description = "Goes in every generated kid (cc-principal-<suffix>, cc-grant-<suffix>, cc-staff-<suffix>, pulso-engine-<suffix>). Rotating = a new suffix next to the old key (see docs/secrets-keys.md)."
  type        = string
  default     = "hk1"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,23}$", var.agent_keys_suffix))
    error_message = "agent_keys_suffix must be lowercase letters, digits and dashes (max 24 characters)."
  }
}
