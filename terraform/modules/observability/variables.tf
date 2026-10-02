variable "service_name" {
  type        = string
  description = "Stable service identity used by logs, metrics and traces."
}

variable "log_retention_days" { type = number }
variable "alarm_actions" { type = list(string) }
variable "cluster_name" { type = string }

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
