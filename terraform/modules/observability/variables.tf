variable "alarm_email" {
  type        = string
  description = "Operational destination reserved for infrastructure alarm routing."
}

variable "service_name" {
  type        = string
  description = "Stable service identity used by logs, metrics and traces."
}

variable "metric_namespace" {
  type        = string
  description = "Future CloudWatch metric namespace; no metric stream is provisioned."
}

variable "trace_mode" {
  type        = string
  description = "Future trace-export posture; provider collector/integration remains deferred."
}
variable "log_retention_days" { type = number }
variable "alarm_actions" { type = list(string) }
variable "cluster_name" { type = string }

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
