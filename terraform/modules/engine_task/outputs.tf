output "enabled" {
  value = var.enabled
}

output "log_group_name" {
  value = one(aws_cloudwatch_log_group.this[*].name)
}

output "service_name" {
  value = one(aws_ecs_service.this[*].name)
}

output "task_role_arn" {
  value = one(aws_iam_role.task[*].arn)
}

output "effective_desired_count" {
  description = "desired_count after the kill switch is applied."
  value       = local.desired_count
}
