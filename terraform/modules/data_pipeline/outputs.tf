output "lake_bucket_name" { value = module.lake.bucket_name }
output "lake_bucket_arn" { value = module.lake.bucket_arn }
output "task_role_arn" { value = module.iam.task_role_arn }
output "execution_role_arn" { value = module.iam.execution_role_arn }
output "task_definition_arn" { value = module.task.task_definition_arn }
output "schedule_arn" { value = one(module.schedule[*].schedule_arn) }

# Identity statements for the consumers' own roles (attach them with workload_iam.task_statements).
output "restricted_reader_statements" { value = module.lake.restricted_reader_statements }
output "masked_reader_statements" { value = module.lake.masked_reader_statements }
output "analytics_reader_statements" { value = module.lake.analytics_reader_statements }
output "evaluator_reader_statements" { value = module.lake.evaluator_reader_statements }

# The rendered container definition: secret references are ARNs, never values.
output "container_definition" { value = module.task.container_definition }
