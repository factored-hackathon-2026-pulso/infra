variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }

variable "security_group_id" {
  type        = string
  description = "Load balancer security group (ingress 443 from approved CIDRs only)."
}

variable "certificate_arn" {
  type        = string
  description = "ACM certificate for the HTTPS listener."

  validation {
    condition     = can(regex("^arn:(aws|aws-us-gov|aws-cn):acm:[^:]+:[0-9]{12}:certificate/.+$", var.certificate_arn))
    error_message = "certificate_arn must be an ACM certificate ARN."
  }
}

variable "container_port" {
  type    = number
  default = 8000
}

variable "idle_timeout_seconds" {
  type        = number
  description = "ALB idle timeout; turns wait on an LLM call, so it must exceed the slowest expected turn."
  default     = 120
}

variable "deletion_protection" {
  type    = bool
  default = true
}

variable "enable_waf" {
  type    = bool
  default = true
}

variable "rate_limit_per_5_minutes" {
  type        = number
  description = "Requests per source IP per five minutes before the WAF blocks."
  default     = 2000
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
