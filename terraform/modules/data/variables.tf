variable "artifact_bucket_name" {
  type        = string
  description = "Name reserved for immutable artifact and extract storage."
}

variable "source_bucket_name" {
  type        = string
  description = "Name reserved for approved readonly source data."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
