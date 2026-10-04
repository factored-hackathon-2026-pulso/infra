# STUB replaced by lane A/B. Interface only; the orchestrator takes the real module on merge.
variable "name_prefix" { type = string }
variable "region" { type = string }
variable "vpc_id" { type = string }
variable "db_subnet_ids" { type = list(string) }
variable "sg_db_id" { type = string }

output "db_endpoint" { value = "stub-db.internal" }
output "db_port" { value = 5432 }
output "db_master_secret_ssm_name" { value = "/stub/db-master" }
output "bucket_name" { value = "stub-bucket" }
output "bucket_arn" { value = "arn:aws:s3:::stub-bucket" }
output "ssm_prefix" { value = "/stub" }
output "ssm_parameter_arn_prefix" { value = "arn:aws:ssm:us-east-1:123456789012:parameter/stub" }
output "secret_arn" { value = "arn:aws:secretsmanager:us-east-1:123456789012:secret:stub-abc123" }
output "kms_key_arn" { value = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555" }
