# STUB replaced by lane A/B. Interface only; the orchestrator takes the real module on merge.
variable "name_prefix" { type = string }
variable "vpc_id" { type = string }
variable "private_subnet_ids" { type = list(string) }
variable "platform_instance_id" { type = string }
variable "platform_private_ip" { type = string }
variable "engine_instance_id" { type = string }
variable "engine_private_ip" { type = string }

output "cloudfront_domain_name" { value = "stub.cloudfront.net" }
output "cloudfront_distribution_id" { value = "ESTUB000000000" }
