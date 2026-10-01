output "artifact_bucket_name" {
  value       = var.artifact_bucket_name
  description = "Artifact storage contract; no bucket is created by the baseline."
}

output "source_bucket_name" {
  value       = var.source_bucket_name
  description = "Readonly source storage contract; Terraform never uploads bank data."
}
