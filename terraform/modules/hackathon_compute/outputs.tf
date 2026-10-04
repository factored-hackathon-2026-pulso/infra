output "instance_id" { value = aws_instance.this.id }
output "private_ip" { value = aws_instance.this.private_ip }
output "private_dns" { value = aws_instance.this.private_dns }
output "data_volume_id" { value = local.data_volume_id }
output "private_zone_record" { value = aws_route53_record.this.fqdn }
