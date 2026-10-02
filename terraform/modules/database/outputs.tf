output "database_boundary" {
  value       = { engine = var.database_engine, subnet_ids = var.private_subnet_ids }
  description = "Database placement/engine contract, not a provisioned database."
}
