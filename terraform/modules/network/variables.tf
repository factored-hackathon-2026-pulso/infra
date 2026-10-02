variable "vpc_cidr" {
  type        = string
  description = "CIDR reserved for the Pulso deployment VPC."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs for workload and data placement."
}

variable "public_subnet_cidrs" {
  type        = list(string)
  description = "Public subnet CIDRs reserved for controlled ingress and NAT egress."
}

variable "availability_zones" {
  type        = list(string)
  description = "Availability zones paired with subnet CIDRs by the future network implementation."
}

variable "nat_strategy" {
  type        = string
  description = "Cost/availability choice: none, single, or per_az. No NAT is created by this foundation."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
