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
  type = string
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
