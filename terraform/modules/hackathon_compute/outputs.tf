output "instance_id" { value = aws_instance.this.id }
output "private_ip" { value = aws_instance.this.private_ip }
output "private_dns" { value = aws_instance.this.private_dns }
output "data_volume_id" { value = local.data_volume_id }
output "private_zone_record" { value = aws_route53_record.this.fqdn }
output "instance_arn" { value = aws_instance.this.arn }
output "ami_id" {
  value     = aws_instance.this.ami
  sensitive = true # the public AMI parameter value is marked sensitive by the provider
}
output "user_data_sha256" { value = sha256(local.user_data) }
output "deploy_document_name" { value = aws_ssm_document.deploy.name }
output "image_parameter_names" { value = { for k, p in aws_ssm_parameter.image : k => p.name } }
output "public_dns" { value = aws_instance.this.public_dns }
output "public_ip" { value = aws_instance.this.public_ip }
output "db_volume_id" { value = local.db_volume_id }
output "compose_files" { value = var.compose_files }
output "published_ports" { value = local.allowed_ports }
output "service_env_names" { value = local.service_env_names }
output "extra_bundle_keys" { value = sort(keys(var.extra_bundle_files)) }
