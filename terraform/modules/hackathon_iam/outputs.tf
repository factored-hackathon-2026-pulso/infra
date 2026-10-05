output "instance_profile_name_core" {
  value = aws_iam_instance_profile.host["core"].name
}

output "instance_profile_name_platform" {
  value = aws_iam_instance_profile.host["platform"].name
}

output "instance_profile_name_engine" {
  value = aws_iam_instance_profile.host["engine"].name
}

output "instance_role_arn_core" {
  value = aws_iam_role.host["core"].arn
}

output "instance_role_arn_platform" {
  value = aws_iam_role.host["platform"].arn
}

output "instance_role_arn_engine" {
  value = aws_iam_role.host["engine"].arn
}

output "boundary_policy_arn" {
  description = "Deny-list permissions boundary attached to every host role."
  value       = aws_iam_policy.boundary.arn
}

output "loader_role_arn" {
  description = "ARN of the dedicated loader role, or empty when loader_role_enabled is false."
  value       = var.loader_role_enabled ? aws_iam_role.loader[0].arn : ""
}
