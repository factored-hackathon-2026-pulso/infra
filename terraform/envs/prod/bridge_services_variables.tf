variable "bridge_services_enabled" {
  type        = bool
  default     = false
  description = "Declare the Pulso-owned bridge services (core-runtime, core-exporter, platform-exporter). Nothing is planned while false. Needs engine_platform_enabled and private_endpoints_enabled."
}

variable "bridge_ecr_enabled" {
  type        = bool
  default     = false
  description = "Declare the platform-exporter ECR repository (shared ecr module). core-runtime and core-exporter use <env>/pulso-core (core_ecr)."
}

variable "bridge_core_image" {
  type        = string
  default     = ""
  description = "pulso-core-runtime digest (repo@sha256:<64 hex>) from <env>/pulso-core; serves core-runtime and core-exporter."
}

variable "bridge_platform_exporter_image" {
  type        = string
  default     = ""
  description = "platform-exporter digest (repo@sha256:<64 hex>)."
}

variable "bridge_core_secret_arns" {
  type        = map(string)
  default     = {}
  description = "Core workload slice secrets by ARN: db_app, db_exporter, identity_keys, staff_keys, bridge_service_key, llm_gateway_token."
}

variable "bridge_core_database_security_group_id" {
  type    = string
  default = ""
}

variable "bridge_platform_database_security_group_id" {
  type    = string
  default = ""
}

variable "bridge_manage_core_database_ingress" {
  type    = bool
  default = false
}

variable "bridge_manage_platform_database_ingress" {
  type    = bool
  default = false
}

variable "bridge_llm_gateway_url" {
  type    = string
  default = ""
}

variable "bridge_llm_gateway_security_group_id" {
  type    = string
  default = ""
}

variable "bridge_tenant_id" {
  type    = string
  default = ""
}

variable "bridge_core_instance" {
  type    = string
  default = ""
}

variable "bridge_exporter_binding_ref" {
  type    = string
  default = ""
}

variable "bridge_expected_runtime_db" {
  type    = string
  default = ""
}

variable "bridge_expected_eval_db" {
  type    = string
  default = ""
}

variable "bridge_platform_instance" {
  type    = string
  default = ""
}

variable "bridge_platform_binding_ref" {
  type    = string
  default = ""
}

variable "bridge_runtime_extra_environment" {
  type        = map(string)
  default     = {}
  description = "Extra plain settings for core-runtime (budgets, LLM policy, limits). No secrets."
}

variable "bridge_core_runtime_desired_count" {
  type    = number
  default = 0
}

variable "bridge_core_exporter_desired_count" {
  type    = number
  default = 0
}

variable "bridge_platform_exporter_desired_count" {
  type    = number
  default = 0
}
