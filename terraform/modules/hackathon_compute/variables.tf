variable "name_prefix" { type = string }
variable "region" { type = string }

variable "workload" {
  type        = string
  description = "Which host this instance is: core, platform or engine. Selects the compose bundle and secret slice."

  validation {
    condition     = contains(["core", "platform", "engine"], var.workload)
    error_message = "workload must be core, platform or engine."
  }
}

variable "private_zone_id" {
  type        = string
  description = "Route 53 private hosted zone (lane A). A record <workload>.<zone> points at the host private IP."
}

variable "enabled" {
  type        = bool
  default     = true
  description = "Kill switch: false stops the instance (data volume and snapshots stay)."
}

variable "instance_type" {
  type        = string
  default     = "t3.small"
  description = "x86_64 type. t3.small (2 GB) fits each workload with 30 percent headroom; t3.micro does not."
}

variable "ami_ssm_parameter" {
  type        = string
  default     = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
  description = "Public SSM parameter that resolves the Amazon Linux 2023 x86_64 AMI."
}

variable "subnet_id" {
  type        = string
  description = "PRIVATE subnet (lane A private_subnet_ids[0]); egress goes through the NAT gateway."
}

variable "security_group_ids" { type = list(string) }
variable "instance_profile_name" { type = string }

variable "root_volume_size_gb" {
  type    = number
  default = 20
}

variable "data_volume_size_gb" {
  type    = number
  default = 40
}

variable "protect_data_volume" {
  type        = bool
  default     = true
  description = "true selects the volume with lifecycle prevent_destroy. Set false only for deliberate teardown."
}

variable "ssm_prefix" {
  type        = string
  description = "SSM path of NON-secret config, e.g. /pulso-hk. Names only; values are set out of band."
}

variable "bucket_name" {
  type        = string
  description = "Single data bucket (lane B)."
}

variable "bundle_prefix" {
  type        = string
  default     = "engine/deploy/"
  description = "Prefix in the bucket where the compose bundle is published. Must not be lifecycle-expired."
}

variable "secret_arn" {
  type        = string
  description = "The ONE Secrets Manager secret (JSON) holding every secret. The host role may read exactly this ARN."
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key encrypting the secret; the host role needs kms:Decrypt on it."
}

variable "ecr_registry_url" {
  type        = string
  description = "ECR registry host, e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com"
}

variable "images" {
  type        = map(string)
  description = "Immutable image references (repo@sha256:digest) keyed core, gateway, support_api, support_web, pulso, proxy as the workload needs. No tags."

  validation {
    condition     = alltrue([for v in values(var.images) : can(regex("@sha256:[0-9a-f]{64}$", v))])
    error_message = "Every image must be pinned by @sha256:<64 hex> digest."
  }
}

variable "compose_version" {
  type    = string
  default = "v2.29.7"
}

variable "enable_cloudwatch_agent" {
  type        = bool
  default     = false
  description = "Ship docker json logs to CloudWatch. Needs logs permissions on the instance role."
}

variable "bundle_dir" {
  type    = string
  default = null
}

variable "tags" {
  type    = map(string)
  default = {}
}
