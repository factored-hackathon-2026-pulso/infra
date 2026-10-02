variable "aws_region" {
  type = string
}
variable "vpc_cidr" {
  type = string
}
variable "public_subnet_cidrs" {
  type = list(string)
}
variable "private_subnet_cidrs" {
  type = list(string)
}
variable "availability_zones" {
  type = list(string)
}
variable "nat_strategy" {
  type = string
}
variable "allowed_ingress_cidrs" {
  type = list(string)
}
variable "container_port" {
  type = number
}
variable "github_oidc_thumbprints" {
  type = list(string)
}
variable "github_subjects" {
  type = list(string)
}
variable "permissions_boundary_arn" {
  type = string
}
variable "deploy_policy_json" {
  type = string
}
variable "workload_assume_role_policy_json" {
  type = string
}
variable "workload_policy_json" {
  type = string
}
variable "artifact_bucket_name" {
  type = string
}
variable "source_bucket_name" {
  type = string
}
variable "kms_key_arn" {
  type = string
}
variable "postgres_engine_version" {
  type = string
}
variable "db_instance_class" {
  type = string
}
variable "allocated_storage_gib" {
  type = number
}
variable "max_allocated_storage_gib" {
  type = number
}
variable "backup_retention_days" {
  type = number
}
variable "deletion_protection" {
  type = bool
}
variable "skip_final_snapshot" {
  type = bool
}
variable "multi_az" {
  type = bool
}
variable "image_digest" {
  type = string
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
variable "alarm_email" {
  type = string
}
variable "cpu_alarm_threshold" {
  type = number
}
variable "secret_recovery_window_days" {
  type = number
}
