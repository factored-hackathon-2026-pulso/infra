variable "name" {
  type        = string
  description = "Name prefix for every resource."
}

variable "region" {
  type        = string
  description = "AWS region; used for the AZ names and the S3 endpoint service name. Must match the provider region."
}

variable "vpc_cidr" {
  type        = string
  description = "VPC CIDR. Subnets are carved with cidrsubnet(/24)."
  default     = "10.20.0.0/16"
}

variable "admin_cidr" {
  type        = string
  description = "Optional CIDR allowed to reach the host on 80/443 directly (debugging) on the platform (80) and engine (8080) ports. Empty disables it. There is never an SSH port; use SSM Session Manager."
  default     = ""
}

variable "cloudfront_vpc_origin_sg_id" {
  type        = string
  description = "Optional id of the CloudFront VPC-origin service security group (created by AWS when the first VPC origin exists). Empty relies on the CloudFront origin-facing prefix list only."
  default     = ""
}

variable "zone_name" {
  type        = string
  description = "Private Route 53 hosted zone for service discovery between hosts."
  default     = "pulso.internal"
}

variable "enable_flow_logs" {
  type        = bool
  description = "Create VPC flow logs to CloudWatch Logs. Costs money (ingestion and storage); default off."
  default     = false
}

variable "flow_logs_retention_days" {
  type        = number
  description = "Retention of the flow log group when enabled."
  default     = 7
}

variable "enable_nat" {
  type        = bool
  description = "Create the single NAT gateway (paid hourly). false (free_plan): hosts use the public subnets with public IPs, outbound-only."
  default     = true
}

variable "database_mode" {
  type        = string
  description = "rds: isolated db subnets and the db SG. container: Postgres runs on the core host (no db subnets; core SG accepts 5432 from platform and engine)."
  default     = "rds"

  validation {
    condition     = contains(["rds", "container"], var.database_mode)
    error_message = "database_mode must be rds or container."
  }
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to every resource."
}

variable "agent_services_enabled" {
  type        = bool
  description = "agent-core serve (8001) and tool-service on the core host: open platform -> core:8001 (support-platform calls agent-core) and core -> platform:8000 (agent-core's grant_active check against the platform API)."
  default     = false
}
