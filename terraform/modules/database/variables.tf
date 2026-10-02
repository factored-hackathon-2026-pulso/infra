variable "database_engine" {
  type        = string
  description = "Deferred managed-database engine selection; no database is provisioned by this foundation."
}
variable "security_group_ids" { type = list(string) }
variable "instance_class" { type = string }
variable "backup_retention_days" { type = number }
variable "deletion_protection" { type = bool }
variable "skip_final_snapshot" { type = bool }
variable "multi_az" { type = bool }

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet identifiers reserved for a future database subnet group."
}
variable "kms_key_arn" {
  type = string
}
variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
