output "vpc_id" { value = aws_vpc.this.id }

output "private_subnet_ids" { value = aws_subnet.private[*].id }

output "public_subnet_ids" { value = aws_subnet.public[*].id }

output "nat_strategy" {
  value       = var.nat_strategy
  description = "Selected cost/availability posture; not an active NAT gateway."
}
