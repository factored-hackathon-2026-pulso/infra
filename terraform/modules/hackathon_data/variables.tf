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

variable "restricted_reader_role_arns" {
  description = "Roles that may read data-pipeline's restricted publication (gold_restricted, PII in the clear) besides the loader and break-glass: the core host role when tool-service runs there. Never exempt from the landing/ and lake/bronze/ deny."
  type        = list(string)
  default     = []
}

variable "agent_services_enabled" {
  description = "Seed the secret keys of agent-core serve, tool-service, their gateway consumer, the platform side and the agent databases (docs/agent-services.md). Off by default."
  type        = bool
  default     = false
}

variable "engine_data_mode" {
  description = "PULSO_DATA_MODE of the engine daemon (SSM, derived). dataset = bank aggregates (adapters stub|dataset-*); platform = the platform event log (adapters stub|product-*). Must match PULSO_SOURCE_ADAPTER or `pulso run` refuses to start (config_conflict); the environment root derives it from platform_database_enabled."
  type        = string
  default     = "dataset"

  validation {
    condition     = contains(["dataset", "platform"], var.engine_data_mode)
    error_message = "engine_data_mode must be dataset or platform."
  }
}

variable "platform_database_enabled" {
  description = "Seed the secret keys of the platform and tool-service databases on the shared Postgres (platform, tools) and the engine's read-only access to the platform event log (docs/shared-postgres.md). Off by default."
  type        = bool
  default     = false
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
  description = "Consumer names for GATEWAY_TOKEN_<CONSUMER> keys; a token is generated for each. AGENT_CORE (core-runtime), AGENT_SERVE (agent-core serve) and ENGINE are required."
  type        = list(string)
  default     = ["AGENT_CORE", "AGENT_SERVE", "ENGINE", "SUPPORT_PLATFORM"]

  validation {
    condition     = alltrue([for c in ["AGENT_CORE", "AGENT_SERVE", "ENGINE"] : contains(var.gateway_consumers, c)])
    error_message = "gateway_consumers must include AGENT_CORE, AGENT_SERVE and ENGINE."
  }
}

variable "llm_provider_key_names" {
  description = "Provider API key names stored in the secret. The gateway has one endpoint, openrouter (ssm.tf); add names here only with a matching LLM_ENDPOINTS entry."
  type        = list(string)
  default     = ["OPENROUTER_API_KEY"]
}

variable "bridge_signer_names" {
  description = "Names of the PULSO_BRIDGE_*_SIGNER keys (ASSUMED defaults; confirm with agent-core)."
  type        = list(string)
  default     = ["PULSO_BRIDGE_CONTROL_SIGNER", "PULSO_BRIDGE_LAB_SIGNER"]
}

variable "agent_keys_suffix" {
  description = "Goes in every generated kid (cc-principal-<suffix>, cc-grant-<suffix>, cc-staff-<suffix>, pulso-engine-<suffix>)."
  type        = string
  default     = "hk1"

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{0,23}$", var.agent_keys_suffix))
    error_message = "agent_keys_suffix must be lowercase letters, digits and dashes (max 24 characters)."
  }
}

variable "otlp_forwarder_enabled" {
  description = "Seed the Langfuse secret keys and SSM base URL for the OTLP forwarder sidecars (docs/otlp-forwarder.md). Off by default."
  type        = bool
  default     = false
}

variable "langfuse_base_url" {
  description = "Langfuse base URL the forwarder posts to (https; the forwarder refuses a non-loopback http upstream). Not secret."
  type        = string
  default     = "https://us.cloud.langfuse.com"

  validation {
    condition     = can(regex("^https://[a-z0-9.-]+$", var.langfuse_base_url))
    error_message = "langfuse_base_url must be https://<host> with no path."
  }
}

variable "engine_extra_key_suffixes" {
  description = "Rotation of the engine's Ed25519 key (agent-core docs/serve-env.md section 8): suffixes of EXTRA keys, kid pulso-engine-<suffix>, published beside the first key in identity-keys and staff-keys. Empty = no rotation in progress."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.engine_extra_key_suffixes : can(regex("^[a-z0-9][a-z0-9-]{0,23}$", s)) && s != var.agent_keys_suffix]) && length(distinct(var.engine_extra_key_suffixes)) == length(var.engine_extra_key_suffixes)
    error_message = "engine_extra_key_suffixes are distinct, differ from agent_keys_suffix, lowercase letters, digits and dashes (max 24 characters)."
  }
}

variable "engine_active_key_suffix" {
  description = "Which engine key the engine MINTS with (PULSO_SERVICE_KID and the seed). Null = the first key (agent_keys_suffix). Set to an engine_extra_key_suffixes entry after the new key is published and reloaded by serve."
  type        = string
  default     = null

  validation {
    condition     = var.engine_active_key_suffix == null || var.engine_active_key_suffix == var.agent_keys_suffix || contains(var.engine_extra_key_suffixes, coalesce(var.engine_active_key_suffix, "-"))
    error_message = "engine_active_key_suffix must be agent_keys_suffix or one of engine_extra_key_suffixes."
  }
}

variable "engine_retire_base_key" {
  description = "Drop the first engine key (kid pulso-engine-<agent_keys_suffix>) from the published documents, the last step of a rotation. Needs another key to be active."
  type        = bool
  default     = false
}

variable "auto_loader_enabled" {
  description = "Seed the secret key of the automatic loader (LOADER__PSEUDONYM_KEY, the data pipeline's pseudonymisation HMAC key; out of band). Off by default."
  type        = bool
  default     = false
}

variable "private_zone_name" {
  description = "Private Route 53 zone of the hosts (module.network zone_name). Remote hosts reach the Postgres container as core.<zone>; used to assemble the DSNs Terraform generates."
  type        = string
  default     = "pulso.internal"
}
