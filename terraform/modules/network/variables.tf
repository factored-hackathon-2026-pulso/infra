variable "vpc_cidr" {
  type        = string
  description = "CIDR reserved for the Pulso deployment VPC."
}

variable "private_subnet_cidrs" {
  type        = list(string)
  description = "Private subnet CIDRs for workload and data placement."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
