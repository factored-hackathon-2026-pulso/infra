variable "vpc_id" {
  type        = string
  description = "Future VPC identifier where least-privilege security groups will be placed."
}

variable "allowed_ingress_cidrs" {
  type        = list(string)
  description = "Approved administrative or edge ingress CIDRs; empty is valid for private-only posture."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
