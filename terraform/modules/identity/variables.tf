variable "workload_principal" {
  type        = string
  description = "Runtime service principal selected by a future compute implementation; no OIDC trust is configured."
}

variable "least_privilege_policy_boundary" {
  type        = string
  description = "Versioned policy-boundary reference or JSON digest for future IAM role/policy creation."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
variable "artifact_bucket_arn" { type = string }
variable "source_bucket_arn" { type = string }
variable "runtime_secret_arn" { type = string }
