variable "aws_region" {
  type        = string
  description = "Region for the bootstrap resources. No default on purpose (docs/aws-asks.md AWS-02): the human chooses it."
}

variable "state_bucket_name" {
  type        = string
  description = "Globally unique name of the remote-state bucket. The account id is deliberately not baked in; choose a name that is unique."

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket_name))
    error_message = "state_bucket_name must be a valid lowercase S3 bucket name (3-63 characters: a-z, 0-9, dot, hyphen)."
  }
}

variable "state_key" {
  type        = string
  description = "Object key of the state file for the first environment composition, used only in the emitted backend snippet."
  default     = "pulso/staging-new/terraform.tfstate"
}

variable "tags" {
  type        = map(string)
  description = "Ownership tags applied to every bootstrap resource."
  default = {
    ManagedBy   = "terraform-bootstrap"
    Environment = "bootstrap"
    Service     = "pulso"
  }
}
