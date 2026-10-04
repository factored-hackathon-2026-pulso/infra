# STUB replaced by lane A/B. Interface only; the orchestrator takes the real module on merge.
variable "name_prefix" { type = string }
variable "bucket_arn" { type = string }
variable "ssm_parameter_arn_prefix" { type = string }
variable "secret_arn" { type = string }
variable "kms_key_arn" { type = string }

output "instance_profile_name_core" { value = "stub-core-profile" }
output "instance_profile_name_platform" { value = "stub-platform-profile" }
output "instance_profile_name_engine" { value = "stub-engine-profile" }
output "instance_role_arn" { value = "arn:aws:iam::123456789012:role/stub-host" }
