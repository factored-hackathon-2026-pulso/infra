output "vpc_cidr" {
  value       = var.vpc_cidr
  description = "Contract placeholder until VPC resources are introduced in a reviewed slice."
}

output "private_subnet_cidrs" {
  value       = var.private_subnet_cidrs
  description = "Reserved private subnet contract."
}
