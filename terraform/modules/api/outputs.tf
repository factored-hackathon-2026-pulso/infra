output "api_boundary" {
  value       = { mode = var.api_mode, private_subnet_ids = var.private_subnet_ids }
  description = "API Gateway boundary contract, not a provisioned API or integration."
}
