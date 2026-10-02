variable "name" {
  type = string
}
variable "private_subnet_ids" {
  type = list(string)
}
variable "database_security_group_id" {
  type = string
}
variable "postgres_engine_version" {
  type = string
}
variable "instance_class" {
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
variable "tags" {
  type = map(string)
}
