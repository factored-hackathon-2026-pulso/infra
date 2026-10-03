variable "name_prefix" { type = string }
variable "cluster_name" { type = string }
variable "service_name" { type = string }
variable "relay_service_name" { type = string }
variable "log_group_name" { type = string }
variable "load_balancer_arn_suffix" { type = string }
variable "target_group_arn_suffix" { type = string }
variable "alarm_actions" { type = list(string) }

variable "target_5xx_threshold" {
  type    = number
  default = 5
}

variable "latency_p95_seconds" {
  type        = number
  description = "p95 target response time that raises the alarm; the ALB idle timeout is the hard ceiling."
  default     = 20
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
