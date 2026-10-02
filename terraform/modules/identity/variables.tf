variable "name" {
  type = string
}
variable "github_oidc_thumbprints" {
  type = list(string)
}
variable "github_subjects" {
  type = list(string)
}
variable "permissions_boundary_arn" {
  type = string
}
variable "deploy_policy_json" {
  type = string
}
variable "workload_assume_role_policy_json" {
  type = string
}
variable "workload_policy_json" {
  type = string
}
variable "tags" {
  type = map(string)
}
