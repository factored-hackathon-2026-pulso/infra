output "iam_boundary" {
  value       = { principal = var.workload_principal, policy_boundary = var.least_privilege_policy_boundary }
  description = "IAM role/policy contract, not an active role or federated trust."
}
