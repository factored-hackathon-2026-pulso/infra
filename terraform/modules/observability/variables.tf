variable "name" {
  type = string
}
variable "service_name" {
  type = string
}
variable "cluster_name" {
  type = string
}
variable "db_instance_identifier" {
  type = string
}
variable "alarm_email" {
  type        = string
  default     = null
  nullable    = true
  description = "Optional mailbox. AWS sends a confirmation before alarms can be delivered."
  validation {
    condition     = var.alarm_email == null || can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.alarm_email))
    error_message = "alarm_email must be null or a valid email address."
  }
}
variable "cpu_alarm_threshold" {
  type = number
}
variable "log_retention_days" {
  type = number
}
variable "tags" {
  type = map(string)
}
