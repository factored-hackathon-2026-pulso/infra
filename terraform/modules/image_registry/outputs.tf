output "repository_url" {
  value       = aws_ecr_repository.this.repository_url
  description = "Registry URL the image is pushed to and deployed from, always by digest."
}

output "repository_arn" {
  value = aws_ecr_repository.this.arn
}

output "publisher_role_arn" {
  value       = one(aws_iam_role.publisher[*].arn)
  description = "Role the agent-core workflow assumes through OIDC; null until an OIDC provider is approved."
}
