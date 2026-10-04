variable "name" {
  type        = string
  description = "Name prefix of the projects, roles and log groups, for example pulso-prod. Projects are named <name>-build-<service>."
}

variable "enabled" {
  type        = bool
  default     = false
  description = "Unwired by default: false creates nothing. true creates one CodeBuild project, role and log group per service."
}

variable "region" {
  type        = string
  description = "Region of the ECR registry and of the build projects."
}

variable "bucket_name" {
  type        = string
  description = "The single data bucket. Source zips are read from <source_prefix>/<service>/ and build records written to <output_prefix>/<service>/."
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key of the bucket (objects are SSE-KMS). The build roles may decrypt and encrypt with it."
}

variable "ecr_registry" {
  type        = string
  description = "ECR registry host, <account id>.dkr.ecr.<region>.amazonaws.com."
}

variable "source_prefix" {
  type        = string
  default     = "engine/build-src"
  description = "Key prefix (no slash at the ends) of the source zips: <prefix>/<service>/<id>.zip. Expires after 14 days (hackathon_data)."
}

variable "output_prefix" {
  type        = string
  default     = "engine/build-out"
  description = "Key prefix (no slash at the ends) of the build records: <prefix>/<service>/<id>.json holding {image, digest}. Expires after 14 days."
}

variable "services" {
  type = map(object({
    repository       = string
    dockerfile       = optional(string, "Dockerfile")
    context_dir      = optional(string, ".")
    core_context_dir = optional(string, "")
    mode             = optional(string, "build")
  }))
  description = "Buildable services by name. repository is the ECR repository (for example pulso-prod/core-runtime). dockerfile and context_dir are paths inside the zip. core_context_dir, when set, is the directory of the agent-core checkout inside the zip and becomes --build-context core=<dir>. mode is build (docker build) or mirror (pull a third-party image given as MIRROR_IMAGE and push it to the repository)."
  default     = {}

  validation {
    condition     = alltrue([for k, v in var.services : can(regex("^[a-z0-9][a-z0-9-]{0,40}$", k))])
    error_message = "Service names are lowercase letters, digits and dashes (they become S3 prefixes and project names)."
  }

  validation {
    condition     = alltrue([for k, v in var.services : contains(["build", "mirror"], v.mode)])
    error_message = "mode must be build or mirror."
  }

  validation {
    condition     = alltrue([for k, v in var.services : can(regex("^[a-z0-9][a-z0-9._/-]*$", v.repository)) && !strcontains(v.dockerfile, "..") && !strcontains(v.context_dir, "..") && !strcontains(v.core_context_dir, "..")])
    error_message = "Repository names are lowercase ECR names; paths inside the zip must not contain '..'."
  }
}

variable "compute_type" {
  type        = string
  default     = "BUILD_GENERAL1_MEDIUM"
  description = "CodeBuild compute type (Linux x86_64). MEDIUM is 4 vCPU and 7 GB."
}

variable "timeout_mins" {
  type        = number
  default     = 60
  description = "Build timeout in minutes."
}

variable "build_image" {
  type        = string
  default     = "aws/codebuild/standard:7.0"
  description = "CodeBuild managed image (Docker, buildx and the AWS CLI included)."
}

variable "log_retention_days" {
  type        = number
  default     = 30
  description = "Retention of the build logs."
}

variable "tags" {
  type        = map(string)
  default     = {}
  description = "Tags applied to every resource."
}
