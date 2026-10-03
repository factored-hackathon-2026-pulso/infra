variable "repository_name" {
  type        = string
  description = "ECR repository name, for example staging/agent-core."
}

variable "kms_key_arn" {
  type        = string
  description = "Optional customer-managed KMS key for image encryption; empty selects AES256."
  default     = ""
}

variable "keep_images" {
  type        = number
  description = "How many tagged images to keep as the rollback window."
  default     = 30
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
