variable "database_engine" {
  type        = string
  description = "Deferred managed-database engine selection; no database is provisioned by this foundation."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private subnet identifiers reserved for a future database subnet group."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
