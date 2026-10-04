variable "vpc_id" {
  description = "VPC for the security group (the account's default VPC, resolved by the root)."
  type        = string
}

variable "subnet_id" {
  description = "A default public subnet (no NAT: the instance gets a public IP for egress only)."
  type        = string
}

variable "region" {
  description = "AWS region (used to build resource ARNs for the scoped IAM user)."
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for the bucket name: <prefix>-buildbox-<account id>."
  type        = string
  default     = "pulso-prod"
}

variable "user_name" {
  description = "Scoped IAM user agents use. Terraform never creates an access key for it."
  type        = string
  default     = "pulso-buildbox"
}

variable "instance_type" {
  description = "On-demand build host size."
  type        = string
  default     = "c6i.2xlarge"
}

variable "root_volume_gb" {
  description = "Encrypted root volume size in GB."
  type        = number
  default     = 40
}

variable "data_volume_gb" {
  description = "Encrypted gp3 data volume mounted at /work (cargo registry, target caches, job dirs)."
  type        = number
  default     = 100
}

variable "idle_minutes" {
  description = "Minutes without a running job (marker files in /work/.jobs) before the box stops itself."
  type        = number
  default     = 30
}

variable "expiry_days" {
  description = "Days after which objects in the buildbox bucket expire."
  type        = number
  default     = 7
}

variable "tags" {
  description = "Extra tags (Purpose=buildbox and Ephemeral=true are always applied)."
  type        = map(string)
  default     = {}
}
