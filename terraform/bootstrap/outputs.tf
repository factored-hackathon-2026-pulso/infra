output "state_bucket" {
  description = "Remote-state bucket name."
  value       = aws_s3_bucket.state.id
}

output "backend_hcl" {
  description = "Contents for the env backend.hcl (kept outside Git). Copy into a local file and pass with -backend-config."
  value       = <<-EOT
    bucket       = "${aws_s3_bucket.state.bucket}"
    key          = "${var.state_key}"
    region       = "${var.aws_region}"
    use_lockfile = true
    encrypt      = true
  EOT
}

output "ecr_repository_names" {
  description = "Created ECR repository names."
  value       = local.ecr_names
}

output "ecr_repository_urls" {
  description = "ECR repository URLs for scripts/release-engine.ps1 -EcrRepository."
  value       = { for n, r in module.ecr : n => r.repository_url }
}

output "deploy_role_arn" {
  description = "ARN of the GitHub OIDC plan/push role (null when OIDC is off)."
  value       = one(aws_iam_role.deploy[*].arn)
}
