output "bucket_name" {
  value = aws_s3_bucket.data.id
}

output "bucket_arn" {
  value = aws_s3_bucket.data.arn
}

output "kms_key_arn" {
  value = aws_kms_key.data.arn
}

output "uploader_policy_json" {
  description = "Identity policy for the human uploader: PUT into landing/ only."
  value       = local.uploader_policy_json
}

output "loader_policy_json" {
  description = "Identity policy for the loader/pipeline role: read landing/ and lake/, write lake/, no delete."
  value       = local.loader_policy_json
}

output "host_policy_json" {
  description = "Identity policy for the host role: masked lake, engine/, core/, tmp/ (never landing/ or lake/bronze/)."
  value       = local.host_policy_json
}

output "db_endpoint" {
  value = one(aws_db_instance.this[*].address)
}

output "db_port" {
  value = one(aws_db_instance.this[*].port)
}

output "secret_arn" {
  description = "The single Secrets Manager secret (JSON). Grant the host read on this one ARN."
  value       = aws_secretsmanager_secret.this.arn
}

output "db_master_secret_ssm_name" {
  description = "Interface-contract name. Holds the NAME of the Secrets Manager secret; the master password is its RDS_MASTER_PASSWORD key (not an SSM parameter)."
  value       = aws_secretsmanager_secret.this.name
}

output "ssm_prefix" {
  value = local.ssm_prefix
}

output "ssm_parameter_arn_prefix" {
  description = "Grant ssm:GetParameter* on <this>/*."
  value       = "arn:aws:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${local.ssm_prefix}"
}

output "origin_verify_secret" {
  description = "Value of the X-Origin-Verify header that CloudFront sends and Caddy enforces (also stored as COMMON__ORIGIN_VERIFY)."
  value       = random_password.origin_verify.result
  sensitive   = true
}
