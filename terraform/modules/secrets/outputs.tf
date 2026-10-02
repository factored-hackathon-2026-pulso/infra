output "secrets_boundary" {
  value       = { prefix = var.secret_name_prefix, kms_key_arn = var.kms_key_arn }
  description = "Secrets Manager naming/encryption contract; no secret or value is provisioned."
}
