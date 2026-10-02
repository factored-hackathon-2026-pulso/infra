variable "name" {
  type = string
}
variable "aws_region" {
  type        = string
  description = "AWS region used to restrict runtime CMK use to S3 and Secrets Manager service paths."
}
variable "github_oidc_provider_arn" {
  type        = string
  description = "Account-level GitHub Actions OIDC provider ARN, bootstrapped once outside environment roots."
  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:oidc-provider/token.actions.githubusercontent.com$", var.github_oidc_provider_arn))
    error_message = "github_oidc_provider_arn must name the shared GitHub Actions OIDC provider in this AWS account."
  }
}
variable "github_subjects" {
  type = list(string)
}
variable "permissions_boundary_arn" {
  type = string
}
variable "deploy_policy_json" {
  type = string
}
variable "runtime_secret_arn" {
  type = string
}
variable "source_bucket_arn" {
  type = string
}
variable "artifact_bucket_arn" {
  type = string
}
variable "kms_key_arn" {
  type        = string
  description = "The CMK used by the runtime secret and the source/artifact S3 buckets."
}
variable "tags" {
  type = map(string)
}
