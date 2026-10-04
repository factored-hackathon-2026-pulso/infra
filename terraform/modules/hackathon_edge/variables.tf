variable "name" {
  type        = string
  description = "Name prefix for edge resources."
}

variable "platform_origin_arn" {
  type        = string
  description = "ARN of the support-platform host instance (or an internal ALB/NLB in front of it)."
}

variable "platform_origin_host" {
  type        = string
  description = "DNS name of the platform origin (the instance private DNS name, or the load balancer DNS name)."
}

variable "platform_http_port" {
  type        = number
  description = "Platform origin HTTP port."
  default     = 80
}

variable "engine_origin_arn" {
  type        = string
  description = "ARN of the engine (pulso) host instance (or an internal ALB/NLB in front of it)."
}

variable "engine_origin_host" {
  type        = string
  description = "DNS name of the engine origin."
}

variable "engine_http_port" {
  type        = number
  description = "Engine origin HTTP port."
  default     = 8080
}

variable "engine_path_pattern" {
  type        = string
  description = "Path pattern routed to the engine; everything else goes to the platform."
  default     = "/pulso/*"
}

variable "origin_protocol_policy" {
  type        = string
  description = "CloudFront to origin protocol: http-only (default; the hop stays on the AWS network inside a VPC origin) or https-only (needs a certificate on the host proxy)."
  default     = "http-only"

  validation {
    condition     = contains(["http-only", "https-only", "match-viewer"], var.origin_protocol_policy)
    error_message = "Use http-only, https-only or match-viewer."
  }
}

variable "origin_mode" {
  type        = string
  description = "vpc: CloudFront VPC origins to private hosts (prod). public: plain origins on the host public DNS name (free_plan; host SG = CloudFront prefix list only, plus the secret header)."
  default     = "vpc"

  validation {
    condition     = contains(["vpc", "public"], var.origin_mode)
    error_message = "origin_mode must be vpc or public."
  }
}

variable "origin_secret" {
  type        = string
  description = "Value of the X-Origin-Verify header sent to both origins; the reverse proxies reject requests without it. Empty omits the header."
  default     = ""
  sensitive   = true

  validation {
    condition     = var.origin_mode != "public" || nonsensitive(var.origin_secret) != ""
    error_message = "origin_secret is required in public origin mode: the proxy rejects requests that do not carry it."
  }
}

variable "origin_secret_header_name" {
  type        = string
  description = "Name of the verification header."
  default     = "X-Origin-Verify"
}

variable "price_class" {
  type        = string
  description = "CloudFront price class; PriceClass_100 is the cheapest."
  default     = "PriceClass_100"
}

variable "enable_waf" {
  type        = bool
  description = "Create and attach a WAFv2 web ACL (scope CLOUDFRONT, created through the aws.us_east_1 provider alias). Not free: about 5 USD/month ACL, 1 USD per rule (3 rules), 0.60 USD per million requests."
  default     = true
}

variable "waf_rate_limit" {
  type        = number
  description = "Max requests per IP per evaluation window before the rate-based rule blocks."
  default     = 1000
}

variable "waf_rate_window_seconds" {
  type        = number
  description = "Rate-based rule evaluation window: 60, 120, 300 or 600."
  default     = 300
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource."
}
