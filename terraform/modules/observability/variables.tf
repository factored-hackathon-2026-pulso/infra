variable "alarm_email" {
  type        = string
  description = "Operational destination reserved for infrastructure alarm routing."
}

variable "service_name" {
  type        = string
  description = "Stable service identity used by logs, metrics and traces."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
