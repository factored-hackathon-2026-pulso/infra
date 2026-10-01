variable "image_digest" {
  type        = string
  description = "Approved immutable engine image digest consumed by deployment."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet IDs where runtime compute may be scheduled."
}

variable "security_group_ids" {
  type        = list(string)
  description = "Least-privilege security group IDs attached to compute."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
