variable "api_mode" {
  type        = string
  description = "Deferred API Gateway exposure choice; no API, route or provider integration is created."
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private network boundary supplied to a future API integration design."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
