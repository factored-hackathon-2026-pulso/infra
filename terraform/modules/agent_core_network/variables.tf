variable "vpc_id" {
  type        = string
  description = "VPC where the Agent Core security groups are created."
}

variable "ingress_cidrs" {
  type        = list(string)
  description = "Internal CIDRs allowed to reach the load balancer on 443. Never 0.0.0.0/0."

  validation {
    condition     = alltrue([for c in var.ingress_cidrs : can(cidrhost(c, 0)) && c != "0.0.0.0/0"])
    error_message = "ingress_cidrs must be valid CIDRs and must not include 0.0.0.0/0."
  }
}

variable "container_port" {
  type        = number
  description = "Port the Agent Core container listens on (ADR 0003 interface contract)."
  default     = 8000
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
