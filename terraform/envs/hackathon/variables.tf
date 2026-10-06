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
  description = "Per host instance type. Null derives it from the profile: free_plan = core m7i-flex.large (8 GB, also runs Postgres), platform t3.small, engine m7i-flex.large when auto_loader_enabled (else t3.small; m7i-flex.large is the largest Free Plan type, flex xlarge is not on the list); prod = t3.small x3. In the free_plan profile only the Free Tier eligible types are accepted."

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

  validation {
    condition     = !var.otlp_forwarder_enabled || (contains(keys(var.images.core), "forwarder") && contains(keys(var.images.engine), "forwarder"))
    error_message = "otlp_forwarder_enabled needs images.core.forwarder and images.engine.forwarder (digest of the OTLP forwarder image)."
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
  default     = ""
  description = "OPTIONAL extra arguments of `agentcore serve` (AGENT_SERVE_ARGS in .env). The seven real pieces are serve's defaults (agent-core docs/serve-env.md section 2), so the default is empty; set only for a deliberate override such as --agents. Never a testing.* piece, never a demo-doubles switch."

  validation {
    condition     = !strcontains(var.agent_serve_args, "testing.") && !can(regex("(?i)allow[-_]?(doubles|demo)", var.agent_serve_args)) && !can(regex("[\r\n]", var.agent_serve_args))
    error_message = "agent_serve_args is one line and never takes testing.* doubles or an allow-doubles switch (AGENTCORE_ALLOW_DOUBLES is prohibited in deployments)."
  }
}

variable "agent_serve_agents" {
  type        = string
  default     = "recepcion,disputas,consultas,copiloto-asesor"
  description = "AGENTCORE_SERVE_AGENTS: agents (comma separated) whose `prod` release serve checks at start (it only warns)."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9_-]*(,[a-z0-9][a-z0-9_-]*)*$", var.agent_serve_agents))
    error_message = "agent_serve_agents is a comma separated list of agent ids."
  }
}

variable "agent_proposal_quota_per_day" {
  type        = number
  default     = 30
  description = "AGENTCORE_PROPOSAL_QUOTA_PER_DAY: proposals the autonomous builder (origin=auto_detect) may create per rolling 24 h; beyond it the API answers quota_exceeded. Config, not a secret. agent-core's own default is 10; tripled here."

  validation {
    condition     = var.agent_proposal_quota_per_day >= 1 && floor(var.agent_proposal_quota_per_day) == var.agent_proposal_quota_per_day
    error_message = "agent_proposal_quota_per_day is a positive integer (serve refuses to start otherwise)."
  }
}

variable "agent_proposal_quota_overrides" {
  type        = string
  default     = "pulso-engine=600"
  description = "AGENTCORE_PROPOSAL_QUOTA_OVERRIDES: `principal=limit,principal=limit`. The improvement engine (principal pulso-engine) creates 2-3 proposals per finding (proof scratch + deliverable); that principal counts only its own proposals. Config, not a secret."

  validation {
    condition     = var.agent_proposal_quota_overrides == "" || can(regex("^[A-Za-z0-9][A-Za-z0-9_.:-]*=[1-9][0-9]*(,[A-Za-z0-9][A-Za-z0-9_.:-]*=[1-9][0-9]*)*$", var.agent_proposal_quota_overrides))
    error_message = "agent_proposal_quota_overrides is `principal=limit` pairs separated by commas, limits positive integers."
  }
}

variable "otlp_forwarder_enabled" {
  type        = bool
  default     = false
  description = "OTLP forwarder sidecars (docs/otlp-forwarder.md, decision B1): one in the network namespace of llm-gateway and one of agent-core on the core host, one of pulso on the engine host, each the single loopback egress to Langfuse. Needs images.core.forwarder and images.engine.forwarder (digest of the forwarder image) and the secret keys LANGFUSE__LANGFUSE_PUBLIC_KEY and _SECRET_KEY. Off by default."
}

variable "otlp_trace_content" {
  type        = bool
  default     = false
  description = "Export prompt and response content to Langfuse (LLM_GATEWAY_TRACE_CONTENT, AGENTCORE_TRACE_CONTENT, PULSO_O11Y_CAPTURE_CONTENT). Default false: only structure and timings leave the host. Full content is authorized for Langfuse US by the owner, but it is still a deliberate switch."
}

variable "langfuse_base_url" {
  type        = string
  default     = "https://us.cloud.langfuse.com"
  description = "Langfuse base URL for the forwarder (https, not secret)."
}

variable "engine_loop_enabled" {
  type        = bool
  default     = false
  description = "The improvement-loop job on the engine host (docs/engine-loop.md): `pulso loop` as a systemd one-shot with a timer, minted registry credentials, the S3 inputs mirror. Needs agent_services_enabled (the Core is agent-core serve) and an engine image with python3 and the regression scripts. Off by default."

  validation {
    condition     = !var.engine_loop_enabled || var.agent_services_enabled
    error_message = "engine_loop_enabled needs agent_services_enabled: the loop writes proposals to agent-core serve."
  }
}

variable "engine_loop_interval" {
  type        = string
  default     = "6h"
  description = "Time between the end of a loop run and the next (systemd span: 90min, 6h, 1d)."

  validation {
    condition     = can(regex("^[0-9]+(min|h|d)$", var.engine_loop_interval))
    error_message = "engine_loop_interval is a number plus min, h or d."
  }
}

variable "engine_loop_cells_source" {
  type        = string
  default     = "bank"
  description = "PULSO_CELLS_SOURCE of the loop: what the cells are. bank (the loader's bank cells, default), e0, or synthetic (demo profile only)."

  validation {
    condition     = contains(["bank", "e0", "synthetic"], var.engine_loop_cells_source)
    error_message = "engine_loop_cells_source is bank, e0 or synthetic."
  }
}

variable "engine_loop_profile" {
  type        = string
  default     = "standard"
  description = "PULSO_PROFILE of the loop: standard (default) or demo (lower support floors; the engine refuses it unless the cells are synthetic)."

  validation {
    condition     = contains(["standard", "demo"], var.engine_loop_profile) && (var.engine_loop_profile != "demo" || var.engine_loop_cells_source == "synthetic")
    error_message = "engine_loop_profile is standard or demo, and demo only with engine_loop_cells_source = synthetic."
  }
}

variable "engine_extra_key_suffixes" {
  type        = list(string)
  default     = []
  description = "Engine key rotation, step 1: suffixes of extra engine Ed25519 keys (kid pulso-engine-<suffix>) published beside the first key. docs/agent-core-serve.md section 5."
}

variable "engine_active_key_suffix" {
  type        = string
  default     = null
  description = "Engine key rotation, step 2: which engine key the engine mints with (null = the first key)."
}

variable "engine_retire_base_key" {
  type        = bool
  default     = false
  description = "Engine key rotation, step 3: stop publishing the first engine key."
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

variable "image_builder_engine_compute_type" {
  type        = string
  default     = null
  description = "CodeBuild compute type of the pulso-engine build only (Rust release build inside docker build, 120 minute timeout). Null: BUILD_GENERAL1_MEDIUM (7 GB, 4 vCPU) in every profile. Pass -BuildArg CARGO_BUILD_JOBS=4 to aws-prod.ps1 images (the Dockerfile default is 1, sized for 4 GB laptops)."
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
  default     = "/usr/local/lib/pulso-loader/run-bank-cells.sh"
  description = "Command (run by bash in the loader, with CELLS_OUT, RUN_KEY, LOADER_BUCKET, LOADER_DATASET_PREFIX, LOADER_K_MIN and the loader credentials in ITS environment only) that writes the bank_cells NDJSON to $CELLS_OUT. Default: the bundled run-bank-cells.sh (bank_cells.py from the engine image over landing/bank, docs/auto-loader.md), so cells are automatic. Empty = no cells export (the operator then uploads engine/inputs/cells.ndjson by hand). The k>=10 gate runs on its output before anything is published."
}

variable "loader_memory" {
  type        = string
  default     = "4g"
  description = "docker --memory of the pipeline container. Default 4g on the 8 GiB engine host (m7i-flex.large, the largest Free Plan type; the loader measurement was skipped by decision). The full build (15.6M events, 4.4M transactions) is unmeasured on EC2."
}

variable "loader_cpus" {
  type        = string
  default     = "2.0"
  description = "docker --cpus of the pipeline container."
}

variable "loader_duckdb_memory" {
  type        = string
  default     = "3GB"
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
