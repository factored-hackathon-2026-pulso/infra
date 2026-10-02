output "storage_boundary" {
  value       = { artifacts = var.artifact_bucket_name, source = var.source_bucket_name }
  description = "Storage naming boundary; no bucket or data is provisioned by this foundation."
}
