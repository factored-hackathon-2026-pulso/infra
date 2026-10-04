variable "region" {
  description = "AWS region."
  type        = string
  default     = "us-east-1"
}

variable "instance_type" {
  description = "On-demand build host size."
  type        = string
  default     = "c6i.2xlarge"
}

variable "data_volume_gb" {
  description = "Encrypted data volume mounted at /work."
  type        = number
  default     = 100
}
