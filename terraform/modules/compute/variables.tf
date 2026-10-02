variable "name" {
  type = string
}
variable "aws_region" {
  type = string
}
variable "image_digest" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "security_group_ids" {
  type = list(string)
}
variable "execution_role_arn" {
  type = string
}
variable "task_role_arn" {
  type = string
}
variable "database_endpoint" {
  type = string
}
variable "runtime_database_secret_arn" {
  type = string
}
variable "rds_master_secret_arn_guard" {
  type        = string
  description = "Terraform-only invariant input; never propagated to ECS task configuration or IAM."
}
variable "container_port" {
  type = number
}
variable "task_cpu" {
  type = number
}
variable "task_memory" {
  type = number
}
variable "desired_count" {
  type = number
}
variable "log_retention_days" {
  type = number
}
variable "tags" {
  type = map(string)
}
