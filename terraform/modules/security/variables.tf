variable "name" {
  type = string
}
variable "vpc_id" {
  type = string
}
variable "allowed_ingress_cidrs" {
  type = list(string)
}
variable "container_port" {
  type = number
}
variable "tags" {
  type = map(string)
}
