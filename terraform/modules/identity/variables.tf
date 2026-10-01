variable "github_repository" {
  type        = string
  description = "Repository allowed to assume environment-scoped deployment roles through OIDC."
}

variable "environment_name" {
  type        = string
  description = "GitHub and AWS deployment environment name."
}

variable "tags" {
  type        = map(string)
  description = "Mandatory ownership and environment tags."
}
