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
  value = aws_db_instance.this.address
}

output "db_port" {
  value = aws_db_instance.this.port
}
