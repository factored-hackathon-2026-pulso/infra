variable "repository_name" {
  type        = string
  description = "ECR repository name for the image, for example pulso/agent-core."

  validation {
    condition     = can(regex("^[a-z0-9]+([._/-][a-z0-9]+)*$", var.repository_name))
    error_message = "repository_name must be a valid lowercase ECR repository name."
  }
}

variable "kms_key_arn" {
  type        = string
  description = "Customer-managed KMS key for the repository; empty selects AES256 with an AWS-owned key."
}

variable "github_oidc_provider_arn" {
  type        = string
  description = "Approved account-level GitHub OIDC provider; empty (or no publish_subjects) creates no publisher role."
}

variable "publish_subjects" {
  type        = list(string)
  description = "Exact OIDC subjects allowed to assume the publisher role: protected GitHub environments only."

  validation {
    condition     = alltrue([for s in var.publish_subjects : can(regex("^repo:[^*?/]+/[^*?/]+:environment:[^*?:]+$", s))])
    error_message = "publish_subjects must be exact repo:<owner>/<repo>:environment:<name> values (a protected environment); branch, tag and pull request subjects are not accepted."
  }
}

variable "least_privilege_policy_boundary" {
  type        = string
  description = "Versioned policy-boundary reference for the publisher role; empty applies none."
}

variable "untagged_retention_days" {
  type        = number
  description = "Days an untagged image is kept before it expires."
}

variable "max_images" {
  type        = number
  description = "Upper bound on stored images; the oldest expire first. Keep it above the digests still deployed."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
