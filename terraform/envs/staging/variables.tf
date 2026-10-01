variable "aws_region" {
  type = string
}

variable "github_repository" {
  type = string
}

variable "image_digest" {
  type = string
}

variable "alarm_email" {
  type = string
}

variable "vpc_cidr" {
  type = string
}

variable "private_subnet_cidrs" {
  type = list(string)
}

variable "artifact_bucket_name" {
  type = string
}

variable "source_bucket_name" {
  type = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "security_group_ids" {
  type = list(string)
}
