variable "aws_region" { type = string }
variable "vpc_cidr" { type = string }
variable "public_subnet_cidrs" { type = list(string) }
variable "private_subnet_cidrs" { type = list(string) }
variable "availability_zones" { type = list(string) }
variable "nat_strategy" { type = string }
variable "least_privilege_policy_boundary" { type = string }
variable "image_digest" { type = string }
variable "artifact_bucket_name" { type = string }
variable "source_bucket_name" { type = string }
variable "database_engine" { type = string }
variable "secret_name_prefix" { type = string }
variable "kms_key_arn" { type = string }
variable "runtime_database_secret_arn" {
  type        = string
  description = "Externally bootstrapped application-role secret ARN; never the RDS master secret."
}
variable "desired_count" { type = number }
variable "database_instance_class" { type = string }
variable "database_backup_retention_days" { type = number }
variable "database_deletion_protection" { type = bool }
variable "database_skip_final_snapshot" { type = bool }
variable "database_multi_az" { type = bool }
variable "log_retention_days" { type = number }
variable "alarm_actions" { type = list(string) }

# --- Agent Core workload (ADR 0005) ------------------------------------------------------------------------------
variable "agent_core_image" {
  type        = string
  description = "Agent Core image pinned by digest: repository@sha256:<64 hex>."
}
variable "agent_core_certificate_arn" {
  type        = string
  description = "ACM certificate ARN for the internal HTTPS listener."
}
variable "agent_core_ingress_cidrs" {
  type        = list(string)
  description = "Internal CIDRs allowed to reach the load balancer on 443; never 0.0.0.0/0."
}
variable "agent_core_database_secret_arn" {
  type        = string
  description = "Externally bootstrapped application-role secret of the Agent Core database; never the RDS master secret."
}
variable "agent_core_blob_bucket_name" {
  type        = string
  description = "Globally unique name of the registry blob bucket."
}
variable "agent_core_event_consumers" {
  type = map(object({
    event_types                = list(string)
    max_receive_count          = optional(number, 5)
    visibility_timeout_seconds = optional(number, 60)
  }))
  description = "One SQS queue (and DLQ) per consumer of the outbound events, filtered by event_type."
  default     = {}
}
variable "agent_core_extra_secret_names" {
  type        = list(string)
  description = "Extra secret entries (environment variable names), for example one API key per LLM endpoint."
  default     = []
}
variable "agent_core_serve_agents" {
  type    = string
  default = ""
}
variable "agent_core_allow_demo" {
  type        = bool
  description = "AGENTCORE_ALLOW_DEMO=1. Only the hackathon prod demo may enable it."
  default     = false
}
variable "agent_core_desired_count" {
  type    = number
  default = 0
}
variable "agent_core_min_count" {
  type    = number
  default = 0
}
variable "agent_core_max_count" {
  type    = number
  default = 4
}
variable "agent_core_otel_environment" {
  type    = map(string)
  default = {}
}
