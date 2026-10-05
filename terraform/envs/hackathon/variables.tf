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

variable "agent_serve_args" {
  type        = string
  default     = "--tools agent_core.adapters.tools:http_tool_executor --authz agent_core.adapters.policy_authz:policy_authz --field-classifier agent_core.adapters.classification:field_classifier --grant-active agent_core.adapters.grants:http_grant_active"
  description = "Piece flags of `agentcore serve` (module:attribute of REAL pieces; serve refuses testing.* without the demo flag). Add --transcript, --calibration and --classifier once agent-core ships them, and --agents/--lang-thresholds as needed. The path of --field-classifier moves to agent_core.composition.classification with agent-core PR #38."

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
  default     = true
  description = "Attach the loader policy (read landing/ and lake/, write lake/) to the ENGINE host role so the loader runs on the engine host. Core and platform never get it. Set false to use a dedicated loader role via loader_role_arns."
}

variable "loader_role_arns" {
  type        = list(string)
  default     = []
  description = "Extra roles allowed to read landing/ and lake/bronze/ (PII in the clear). The engine host role is added automatically when engine_host_can_load is true."
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
