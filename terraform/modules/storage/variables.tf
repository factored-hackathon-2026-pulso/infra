variable "artifact_bucket_name" {
  type        = string
  description = "Reserved immutable artifact/extract bucket name."
}

variable "source_bucket_name" {
  type        = string
  description = "Reserved readonly source-data bucket name; Terraform never uploads dataset bytes."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
