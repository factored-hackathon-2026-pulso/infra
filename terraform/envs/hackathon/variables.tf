variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "pulso-hk"
}

variable "enabled" {
  type        = map(bool)
  default     = { core = true, platform = true, engine = true }
  description = "Per-host kill switch: false stops that instance."
}

variable "instance_types" {
  type    = map(string)
  default = { core = "t3.small", platform = "t3.small", engine = "t3.small" }
}

variable "data_volume_size_gb" {
  type    = map(number)
  default = { core = 20, platform = 20, engine = 40 }
}

variable "protect_data_volume" {
  type    = bool
  default = true
}

variable "enable_cloudwatch_agent" {
  type    = bool
  default = false
}

variable "ecr_registry_url" { type = string }

variable "images" {
  type = object({
    core     = map(string)
    platform = map(string)
    engine   = map(string)
  })
  description = "Digest-pinned image refs per host. core: core, gateway. platform: support_api, support_web, proxy. engine: pulso, proxy."
}

variable "enable_waf" {
  type        = bool
  default     = true
  description = "WAFv2 web ACL on the distribution (about 8 USD per month plus requests). Set false to save the cost."
}

variable "loader_role_arns" {
  type        = list(string)
  default     = []
  description = "Roles allowed to read landing/ and lake/bronze/ (PII in the clear): the data loader."
}

variable "uploader_principal_arns" {
  type        = list(string)
  default     = []
  description = "Principals (the human uploading the data) allowed to PUT into landing/."
}

variable "break_glass_principal_arns" {
  type        = list(string)
  default     = []
  description = "Principals exempt from the landing/ VPC-endpoint restriction and the PII deny (keep to the account admin role)."
}
