variable "name_prefix" {
  description = "Prefix for every resource name, for example pulso-hackathon."
  type        = string
}

variable "region" {
  description = "AWS region, used only to build ARNs for the SSM prefix."
  type        = string
}

variable "vpc_id" {
  description = "VPC id. Accepted for the interface contract; the database is placed by db_subnet_ids and sg_db_id."
  type        = string
}

variable "db_subnet_ids" {
  description = "Isolated database subnets (at least two AZs are required by RDS even for a single-AZ instance)."
  type        = list(string)
}

variable "sg_db_id" {
  description = "Security group of the database (ingress from the host only; owned by the network module)."
  type        = string
}

variable "db_instance_class" {
  description = "db.t4g.micro (cheapest, ARM) or db.t3.micro."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage_gb" {
  type    = number
  default = 20
}

variable "db_backup_retention_days" {
  description = "7 by default; 1 is the cheapest. 0 disables backups and is not allowed."
  type        = number
  default     = 7
  validation {
    condition     = var.db_backup_retention_days >= 1 && var.db_backup_retention_days <= 35
    error_message = "Backups must stay enabled (1 to 35 days)."
  }
}

variable "db_deletion_protection" {
  type    = bool
  default = true
}

variable "db_skip_final_snapshot" {
  description = "Set true only to tear a throwaway hackathon stack down without a final snapshot."
  type        = bool
  default     = false
}

variable "db_max_connections" {
  type    = number
  default = 40
}

variable "enable_redis" {
  description = "Reserved toggle for an optional cache. Off by default; ElastiCache is NOT free-tier (cache.t4g.micro is roughly 12 USD per month). Not implemented in this module."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}
