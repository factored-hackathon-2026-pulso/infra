output "project_names" {
  description = "CodeBuild project name per service (empty while disabled)."
  value       = local.project_names
}

output "project_arns" {
  description = "CodeBuild project ARN per service, for the deployer policies."
  value       = { for k, v in local.active : k => "arn:${local.partition}:codebuild:${var.region}:${local.account_id}:project/${local.project_names[k]}" }
}

output "source_prefix" {
  value = var.source_prefix
}

output "output_prefix" {
  value = var.output_prefix
}
