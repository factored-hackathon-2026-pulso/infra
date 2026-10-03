output "service_name" { value = aws_ecs_service.serve.name }
output "relay_service_name" { value = aws_ecs_service.relay.name }
output "log_group_name" { value = aws_cloudwatch_log_group.this.name }
output "task_role_arn" { value = aws_iam_role.task.arn }
output "execution_role_arn" { value = aws_iam_role.execution.arn }

output "secret_arns" {
  description = "Secret entries whose values must be set out of band before the first deployment."
  value       = local.secret_arns
}

output "migrate_task_definition_arn" {
  description = "Run once before a service update: aws ecs run-task --task-definition <family> ..."
  value       = aws_ecs_task_definition.role["migrate"].arn
}

output "migrate_task_family" { value = aws_ecs_task_definition.role["migrate"].family }
