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
  type    = map(string)
  default = { core = "t3.small", platform = "t3.small", engine = "t3.small" }
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
  description = "Digest-pinned FULL image refs per host (<registry>/<repo>@sha256:...), as printed by scripts/aws-prod.ps1 images. core: core, gateway. platform: support_api, support_web, proxy. engine: pulso, proxy."
}

variable "enable_waf" {
  type        = bool
  default     = true
  description = "WAFv2 web ACL on the distribution (about 8 USD per month plus requests). Set false to save the cost."
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
