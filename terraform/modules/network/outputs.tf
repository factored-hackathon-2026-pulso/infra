output "vpc_cidr" {
  value       = var.vpc_cidr
  description = "Contract placeholder until VPC resources are introduced in a reviewed slice."
}

output "private_subnet_cidrs" {
  value       = var.private_subnet_cidrs
  description = "Reserved private subnet contract."
}

output "public_subnet_cidrs" {
  value       = var.public_subnet_cidrs
  description = "Public subnet contract for the future VPC implementation."
}

output "nat_strategy" {
  value       = var.nat_strategy
  description = "Selected cost/availability posture; not an active NAT gateway."
}
