variable "region" {
  type        = string
  description = "AWS region of the whole stack. Single-region prod (N. Virginia)."
  default     = "us-east-1"
}

variable "cloudfront_waf_region" {
  type        = string
  description = "Region of the provider alias that hosts the CLOUDFRONT-scope WAF web ACL. CloudFront accepts only the N. Virginia region here."
  default     = "us-east-1"

  validation {
    condition     = can(regex("^us-east-1$", var.cloudfront_waf_region))
    error_message = "CloudFront-scope WAF web ACLs exist only in the N. Virginia region."
  }
}

variable "environment" {
  type        = string
  description = "Environment name, used in tags. There is exactly one environment: prod."
  default     = "prod"
}

variable "name_prefix" {
  type    = string
  default = "pulso-prod"
}

variable "enabled" {
  type        = map(bool)
  default     = { core = true, platform = true, engine = true }
  description = "Per-host kill switch: false stops that instance."
}

variable "instance_types" {
  type        = map(string)
  default     = null
  description = "Per host instance type. Null derives it from the profile: free_plan = core m7i-flex.large (8 GB, also runs Postgres), platform and engine t3.small; prod = t3.small x3. In the free_plan profile only the Free Tier eligible types are accepted."

  validation {
    condition     = var.instance_types == null || var.profile != "free_plan" || alltrue([for t in values(var.instance_types) : contains(["c7i-flex.large", "m7i-flex.large", "t3.micro", "t3.small", "t4g.micro", "t4g.small", "t8i.micro", "t8i.small"], t)])
    error_message = "The free_plan profile accepts only Free Tier eligible instance types: c7i-flex.large, m7i-flex.large, t3.micro, t3.small, t4g.micro, t4g.small, t8i.micro, t8i.small (t4g is arm64 and needs arm64 images and AMI; prefer x86 types)."
  }
}

variable "data_volume_size_gb" {
  type    = map(number)
  default = { core = 20, platform = 20, engine = 40 }
}

variable "protect_data_volume" {
  type    = bool
  default = true
}

variable "enable_cloudwatch_agent" {
  type    = bool
  default = false
}

variable "ecr_registry_url" {
  type        = string
  default     = null
  description = "Optional. Null derives <account id>.dkr.ecr.<region>.amazonaws.com from the caller identity."
}

variable "images" {
  type = object({
    core     = map(string)
    platform = map(string)
    engine   = map(string)
  })
  description = "Digest-pinned FULL image refs per host (<registry>/<repo>@sha256:...), as printed by scripts/aws-prod.ps1 images. core: core, gateway (and agent, tools with agent_services_enabled). platform: support_api, support_web, proxy. engine: pulso, proxy."

  validation {
    condition     = !var.agent_services_enabled || (contains(keys(var.images.core), "agent") && contains(keys(var.images.core), "tools"))
    error_message = "agent_services_enabled needs images.core.agent (agent-core serve) and images.core.tools (tool-service)."
  }
}

variable "agent_services_enabled" {
  type        = bool
  default     = false
  description = "agent-core serve (core:8001) and tool-service on the core host, wired to support-platform (docs/agent-services.md): compose overrides on core and platform, agent.env/tools.env and FILES__ secret keys, the agent databases, core reads the restricted publication, network paths platform<->core. Off by default."
}

variable "platform_database_enabled" {
  type        = bool
  default     = false
  description = "ONE shared Postgres (core host container) for platform and tool-service next to agent-core's: databases platform and tools, roles platform_owner/platform_app/platform_exporter_ro/tools_owner/tools_app, their secret keys, and the engine's read-only access to the platform event log plus its announce path to the platform (docs/shared-postgres.md). Needs database_mode container (free_plan) and agent_services_enabled. Off by default."

  validation {
    condition     = !var.platform_database_enabled || var.agent_services_enabled
    error_message = "platform_database_enabled needs agent_services_enabled (the engine reaches the platform over the agent-services paths)."
  }
}

variable "agent_serve_args" {
  type        = string
  default     = "--tools agent_core.adapters.tools:http_tool_executor --authz agent_core.adapters.policy_authz:policy_authz --field-classifier agent_core.composition.classification:field_classifier --grant-active agent_core.adapters.grants:http_grant_active --transcript agent_core.composition.transcript:transcript --calibration agent_core.composition.artifacts:calibration --classifier agent_core.composition.artifacts:classifier_provider"
  description = "Piece flags of `agentcore serve`: module:attribute of the seven REAL pieces of agent-core main (serve refuses testing.* without the demo flag). Append --agents or --lang-thresholds as needed."

  validation {
    condition     = !strcontains(var.agent_serve_args, "testing.") && !can(regex("[\\r\\n]", var.agent_serve_args))
    error_message = "agent_serve_args takes real pieces on one line, never testing.* doubles."
  }
}

variable "enable_waf" {
  type        = bool
  default     = null
  description = "WAFv2 web ACL on the distribution (about 8 USD per month plus requests). Null derives it from the profile: on in prod, OFF in free_plan (the free plan may refuse WAF)."
}

variable "engine_host_can_load" {
  type        = bool
  default     = false
  description = "Attach the loader policy (read landing/ and lake/, write lake/) DIRECTLY to the ENGINE host role. Default false (user decision 2026-10-05): the engine host reads aggregates only (lake/gold_masked, lake/gold_analytics). Loading is done by the dedicated loader role (auto_loader_enabled, docs/auto-loader.md). Core and platform never get it."
}

variable "loader_role_arns" {
  type        = list(string)
  default     = []
  description = "Extra roles allowed to read landing/ and lake/bronze/ (PII in the clear). The engine host role is added only when engine_host_can_load is true (default false); the auto loader role is added by auto_loader_enabled."
}

variable "uploader_principal_arns" {
  type        = list(string)
  default     = []
  description = "Principals allowed to PUT into landing/. Empty (default) means the account's IAM users (user/*) and the root user; hosts are roles and never match. Their identity policy (admin) still has to allow the call."
}

variable "break_glass_principal_arns" {
  type        = list(string)
  default     = []
  description = "Principals exempt from the PII deny. Empty (default) means the account's IAM users and root user."
}
variable "db_deletion_protection" {
  type        = bool
  default     = true
  description = "RDS deletion protection. Set false (and apply) before a deliberate teardown."
}

variable "db_skip_final_snapshot" {
  type        = bool
  default     = false
  description = "false keeps a final RDS snapshot on destroy. true skips it (throwaway teardown only)."
}

variable "enable_image_builder" {
  type        = bool
  default     = true
  description = "AWS CodeBuild projects that build (or mirror) the service images from a source zip in the bucket and push them to ECR (scripts/aws-prod.ps1 images -Service ...). No cost while idle; false removes them."
}

variable "image_builder_compute_type" {
  type        = string
  default     = null
  description = "CodeBuild compute type for image builds (Linux x86_64). Null derives it from the profile: BUILD_GENERAL1_SMALL (3 GB, may OOM on the Rust release build: use scripts/aws-prod.ps1 images -Builder host) in free_plan, BUILD_GENERAL1_MEDIUM (7 GB) in prod; BUILD_GENERAL1_LARGE for a slow Rust build."
}

variable "ecr_repository_prefix" {
  type        = string
  default     = "pulso-prod"
  description = "Prefix of the ECR repositories created by terraform/bootstrap (<prefix>/core-runtime, ...). Must match the bootstrap variable of the same name."
}

variable "profile" {
  type        = string
  default     = "free_plan"
  description = "free_plan (default for now): AWS Free Plan account. Core host m7i-flex.large with Postgres as a container, no NAT gateway (hosts in public subnets, outbound-only), CloudFront with public origins, WAF off, CodeBuild SMALL. prod: the previous design (RDS, NAT, VPC origins, WAF, t3.small hosts). Every derived value can still be overridden by its own variable."

  validation {
    condition     = contains(["prod", "free_plan"], var.profile)
    error_message = "profile must be prod or free_plan."
  }
}

variable "database_mode" {
  type        = string
  default     = null
  description = "container (Postgres 16 in the core host compose bundle, own EBS volume, daily snapshots) or rds. Null derives it from the profile: container in free_plan, rds in prod."

  validation {
    condition     = var.database_mode == null || contains(["container", "rds"], var.database_mode)
    error_message = "database_mode must be container or rds."
  }
}

variable "enable_nat" {
  type        = bool
  default     = null
  description = "NAT gateway for private hosts. Null derives it from the profile: off in free_plan (hosts in public subnets with public IPs, inbound closed), on in prod."
}

variable "edge_enabled" {
  type        = bool
  default     = null
  description = "Create the CloudFront distribution (and WAF). Null means on; false brings the stack up without an edge (apply in stages; the hosts stay closed, use SSM for tests)."
}

variable "enable_host_builder" {
  type        = bool
  default     = null
  description = "Let the core host build and push images (scripts/aws-prod.ps1 images -Builder host). Null derives it from the profile: on in free_plan, off in prod."
}

variable "db_volume_size_gb" {
  type        = number
  default     = 30
  description = "Postgres container data volume (free_plan, database_mode=container), snapshotted daily."
}

variable "agent_keys_suffix" {
  description = "Suffix of the generated Ed25519 key ids (cc-principal-<s>, cc-grant-<s>, cc-staff-<s>, pulso-engine-<s>). Rotate by publishing a new suffix (docs/secrets-keys.md)."
  type        = string
  default     = "hk1"
}

variable "auto_loader_enabled" {
  type        = bool
  default     = false
  description = "Automatic data loading in AWS (docs/auto-loader.md): a dedicated loader role that ONLY the engine host role may assume (external id), and on the engine host a systemd timer that polls engine/inbox/READY.json, assumes the role, runs the data-pipeline container (bronze, silver, gold_*, publish/, latest.json last), gates the bank_cells export at k>=10 and drops the credentials. Needs images.engine.pipeline (digest of the data-pipeline image) and the secret key LOADER__PSEUDONYM_KEY. Off by default."

  validation {
    condition     = !var.auto_loader_enabled || contains(keys(var.images.engine), "pipeline")
    error_message = "auto_loader_enabled needs images.engine.pipeline (the data-pipeline image digest)."
  }
}

variable "loader_cells_cmd" {
  type        = string
  default     = ""
  description = "Command (run by bash in the loader, with CELLS_OUT, LOADER_BUCKET and the loader credentials in ITS environment only) that writes the bank_cells NDJSON to $CELLS_OUT. Empty = no cells export in the run. The k>=10 gate runs on its output before anything is published."
}

variable "loader_memory" {
  type        = string
  default     = "1g"
  description = "docker --memory of the pipeline container. The full build (15.6M events, 4.4M transactions) is unmeasured on EC2; on a 2 GiB engine host use a larger engine instance_type."
}

variable "loader_cpus" {
  type        = string
  default     = "1.0"
  description = "docker --cpus of the pipeline container."
}

variable "loader_duckdb_memory" {
  type        = string
  default     = "2GB"
  description = "DuckDB memory_limit passed to the pipeline (DUCKDB_MEMORY_LIMIT; spill to DUCKDB_TEMP_DIRECTORY on the data volume). UNVERIFIED: the data-pipeline profiles do not read these variables yet (docs/auto-loader.md, ask to its owners); docker --memory is the enforced cap."
}

variable "loader_table_batches" {
  type        = string
  default     = ""
  description = "Optional ingest_bank batches, semicolon separated, each a comma list of tables (for example customers,products;complaints), one container per batch so peak memory is one batch. UNVERIFIED contract. Empty = a single ingest_bank step."
}

variable "loader_swap_gb" {
  type        = number
  default     = 4
  description = "Swap file (GiB) on the engine host data volume while auto_loader_enabled; 0 disables."
}
