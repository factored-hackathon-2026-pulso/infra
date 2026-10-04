variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "pulso-hk"
}

variable "enabled" {
  type    = bool
  default = true
}

variable "instance_type" {
  type    = string
  default = "t3.large"
}

variable "data_volume_size_gb" {
  type    = number
  default = 40
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
    core_runtime = string
    llm_gateway  = string
    support_api  = string
    support_web  = string
    pulso        = string
    proxy        = string
  })
  description = "Digest-pinned image refs (repo@sha256:...)."
}
