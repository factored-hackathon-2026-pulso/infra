output "vpc_id" {
  value = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnets (NAT gateway only)."
  value       = [for k in sort(keys(aws_subnet.public)) : aws_subnet.public[k].id]
}

output "private_subnet_ids" {
  description = "Host subnets: no public IP, egress via the single NAT."
  value       = [for k in sort(keys(aws_subnet.private)) : aws_subnet.private[k].id]
}

output "db_subnet_ids" {
  description = "Isolated subnets for the RDS subnet group."
  value       = [for k in sort(keys(aws_subnet.db)) : aws_subnet.db[k].id]
}

output "sg_platform_id" {
  value = aws_security_group.platform.id
}

output "sg_core_id" {
  value = aws_security_group.core.id
}

output "sg_engine_id" {
  value = aws_security_group.engine.id
}

output "sg_host_id" {
  description = "Compatibility alias of sg_platform_id."
  value       = aws_security_group.platform.id
}

output "zone_id" {
  description = "Private hosted zone id; records are created by the compute lane."
  value       = aws_route53_zone.internal.zone_id
}

output "zone_name" {
  value = aws_route53_zone.internal.name
}

output "sg_db_id" {
  value = aws_security_group.db.id
}

output "s3_gateway_endpoint_id" {
  value = aws_vpc_endpoint.s3.id
}

output "nat_gateway_id" {
  value = aws_nat_gateway.this[0].id
}
