output "instance_id" {
  description = "The build host instance id."
  value       = aws_instance.this.id
}

output "bucket" {
  description = "Job tarball / log bucket (7 day expiry)."
  value       = aws_s3_bucket.this.bucket
}

output "user_name" {
  description = "Scoped IAM user. Create its access key in the console, then aws configure --profile pulso-buildbox."
  value       = aws_iam_user.this.name
}

output "user_policy_json" {
  description = "Policy JSON of the scoped user, attachable elsewhere."
  value       = aws_iam_user_policy.this.policy
}

output "how_to_remove" {
  description = "How to remove everything."
  value       = "Delete the access keys of IAM user ${aws_iam_user.this.name} in the console, then run terraform destroy in terraform/envs/buildbox with the admin profile (terraform -chdir=terraform/envs/buildbox destroy), or: scripts/buildbox.ps1 down -AdminProfile <admin>. Verify with: scripts/buildbox.ps1 verify-gone"
}

