output "task_definition_arn" { value = aws_ecs_task_definition.this.arn }
output "service_name" { value = var.create_service ? aws_ecs_service.this[0].name : null }
output "container_definition" {
  value       = local.container
  description = "The rendered container definition (secret references are ARNs, never values)."
}
