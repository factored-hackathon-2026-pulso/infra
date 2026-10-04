variable "region" {
  type        = string
  description = "Region of the stack."
}

variable "ssm_prefix" {
  type        = string
  description = "Root SSM path of the stack, leading slash and no trailing slash (for example /pulso). Image digests live at <ssm_prefix>/<workload>/images/<key>."
}

variable "bucket_name" {
  type        = string
  description = "The single data bucket (build-src/ and build-out/ prefixes)."
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key of the bucket: uploading a source zip and reading a build record need it."
}

variable "source_prefix" {
  type        = string
  default     = "engine/build-src"
  description = "Key prefix of the build source zips (see image_builder)."
}

variable "output_prefix" {
  type        = string
  default     = "engine/build-out"
  description = "Key prefix of the build records (see image_builder)."
}

variable "document_name_prefix" {
  type        = string
  default     = "pulso-deploy"
  description = "SSM Command documents are named <prefix>-<workload> (hackathon_compute)."
}

variable "instance_tag_key" {
  type        = string
  default     = "Workload"
  description = "Tag on each host that holds the workload name; ssm:SendCommand is limited to instances carrying it."
}

variable "workloads" {
  type = map(object({
    image_keys     = list(string)
    repositories   = list(string)
    build_services = list(string)
  }))
  description = "Per workload (core, platform, engine): the SSM image keys a team may write (never the shared proxy), the ECR repositories it may push and pull, and the image_builder services it may build."
}

variable "project_arns" {
  type        = map(string)
  default     = {}
  description = "CodeBuild project ARN per build service (image_builder output project_arns). Empty while the builder is off: the policies then carry no CodeBuild statement."
}
