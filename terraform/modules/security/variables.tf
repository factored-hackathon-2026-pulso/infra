variable "vpc_id" {
  type        = string
  description = "Future VPC identifier where least-privilege security groups will be placed."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
