output "security_group_boundary" {
  value       = { vpc_id = var.vpc_id, allowed_ingress_cidrs = var.allowed_ingress_cidrs }
  description = "Security-group policy boundary; no group is provisioned by the foundation."
}
