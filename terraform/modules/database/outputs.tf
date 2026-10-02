output "endpoint" {
  value = aws_db_instance.this.endpoint
}
output "identifier" {
  value = aws_db_instance.this.identifier
}

output "master_user_secret_arn" {
  value = aws_db_instance.this.master_user_secret[0].secret_arn
}
