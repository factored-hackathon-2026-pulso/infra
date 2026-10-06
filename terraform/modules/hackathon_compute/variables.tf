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
  description = "ECR registry host, e.g. <account>.dkr.ecr.<region>.amazonaws.com"
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

variable "associate_public_ip" {
  type        = bool
  default     = false
  description = "Public IP for outbound-only egress (free_plan profile: hosts in public subnets, no NAT gateway). Inbound stays closed by the security groups."
}

variable "db_volume_size_gb" {
  type        = number
  default     = 0
  description = "Size of a dedicated EBS volume for a Postgres container (mounted at /srv/pgdata, snapshotted daily by the same DLM policy). 0 = none."
}

variable "extra_service_envs" {
  type        = list(string)
  default     = []
  description = "Extra service env files rendered from <SERVICE>__<VAR> secret keys and SSM, for example [\"db\"] for the Postgres container on the core host."
}

variable "extra_ports" {
  type        = list(string)
  default     = []
  description = "Extra host:container ports the bundle may publish, for example [\"8001:8001\"] for agent-core serve on the core host (agent services). The security groups decide who reaches them."

  validation {
    condition     = alltrue([for p in var.extra_ports : can(regex("^[0-9]{2,5}:[0-9]{2,5}$", p))])
    error_message = "extra_ports entries are host:container, for example 8001:8001."
  }
}

variable "extra_env" {
  type        = map(string)
  default     = {}
  description = "Extra NON-secret lines for the bundle .env (compose interpolation), for example AGENT_SERVE_ARGS. Secrets never go here."

  validation {
    condition     = alltrue([for k, v in var.extra_env : can(regex("^[A-Z][A-Z0-9_]*$", k)) && !can(regex("[\\r\\n]", v))])
    error_message = "extra_env keys are upper-case variable names and values are single lines."
  }
}

variable "publication_prefix" {
  type        = string
  default     = "lake/publish"
  description = "Key prefix of data-pipeline's publication (latest.json and <run>/). Synced to /srv/data/tools/data/publish when a tools service env is on this host."
}

variable "compose_files" {
  type        = list(string)
  default     = ["compose.yaml"]
  description = "Compose files of the bundle, in order. More than one sets COMPOSE_FILE in .env (docker compose merges them)."
}

variable "extra_bundle_files" {
  type        = map(string)
  default     = {}
  description = "Additional non-secret files published into the bundle (path relative to the bundle root -> content), for example the Postgres compose override and initdb scripts."
}

variable "loader_swap_gb" {
  description = "Size in GiB of a swap file on the data volume, created only on a host that runs the automatic loader (0 = none). A safety net under the loader container's memory cap, not a substitute for RAM."
  type        = number
  default     = 4

  validation {
    condition     = var.loader_swap_gb >= 0 && var.loader_swap_gb <= 16
    error_message = "loader_swap_gb must be 0 to 16."
  }
}

variable "loop_enabled" {
  description = "Install the improvement-loop one-shot (pulso-loop.service + timer, inputs mirror sync, status hook) on the engine host. The bundle must also carry loop/* and compose.loop.yaml (extra_bundle_files, compose_files); the engine env wires that."
  type        = bool
  default     = false
}

variable "loop_interval" {
  description = "systemd time span between the start of one loop run and the start of the next (OnUnitActiveSec of pulso-loop.timer), for example 6h or 90min."
  type        = string
  default     = "6h"

  validation {
    condition     = can(regex("^[0-9]+(min|h|d)$", var.loop_interval))
    error_message = "loop_interval is a number plus min, h or d, for example 6h."
  }
}
