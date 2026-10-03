variable "name_prefix" { type = string }
variable "cluster_name" { type = string }
variable "relay_service_name" { type = string }

variable "log_group_name" {
  type        = string
  description = "Log group written by the relay task; owned by the observability module, never created here."
}

variable "metric_namespace" {
  type    = string
  default = "Pulso/Core"
}

variable "alarm_actions" { type = list(string) }

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
