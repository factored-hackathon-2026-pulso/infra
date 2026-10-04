# STUB replaced by lane A/B. Interface only; the orchestrator takes the real module on merge.
variable "name_prefix" { type = string }
variable "region" { type = string }

output "vpc_id" { value = "vpc-0stub00000000000" }
output "public_subnet_ids" { value = ["subnet-0stubpub0000000a", "subnet-0stubpub0000000b"] }
output "private_subnet_ids" { value = ["subnet-0stubprv0000000a", "subnet-0stubprv0000000b"] }
output "db_subnet_ids" { value = ["subnet-0stubdb00000000a", "subnet-0stubdb00000000b"] }
output "sg_host_id" { value = "sg-0stubhost0000000" }
output "sg_db_id" { value = "sg-0stubdb000000000" }
output "s3_gateway_endpoint_id" { value = "vpce-0stub000000000000" }
output "nat_gateway_id" { value = "nat-0stub000000000000" }
