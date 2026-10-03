# Shared AWS-API VPC endpoints (company-platform foundation, opt-in).
#
# Why: Core's exporter, migrate and sweep tasks have no internet egress (their security groups reach only the VPC
# CIDR and PostgreSQL). Without these endpoints they cannot pull the image from ECR, resolve their secrets or
# write logs. ECR image layers are served from S3, which is reached through a gateway endpoint and a prefix-list
# egress rule (a VPC CIDR rule does not cover it).
#
# enabled = false (default) declares nothing, so adding the module to an environment root changes no plan.
# Cost: each interface endpoint bills per AZ-hour; this is why the module is a flag, not a default.

variable "enabled" {
  type    = bool
  default = false
}

variable "aws_region" { type = string }
variable "vpc_id" { type = string }
variable "vpc_cidr" { type = string }

variable "subnet_ids" {
  type        = list(string)
  description = "Private subnets that host the interface endpoint network interfaces."
}

variable "route_table_ids" {
  type        = list(string)
  description = "Private route tables that receive the S3 gateway endpoint route."
}

variable "customer_kms_in_use" {
  type        = bool
  default     = false
  description = "True when secrets are encrypted with a customer-managed key: tasks then need the KMS endpoint."
}

variable "tags" { type = map(string) }

locals {
  interface_services = toset(concat(
    ["ecr.api", "ecr.dkr", "secretsmanager", "logs"],
    var.customer_kms_in_use ? ["kms"] : [],
  ))
}

resource "aws_security_group" "endpoints" {
  count = var.enabled ? 1 : 0

  name_prefix = "${var.tags["Environment"]}-pulso-vpce-"
  description = "Interface endpoints: HTTPS from the VPC only; no egress."
  vpc_id      = var.vpc_id
  tags        = var.tags
}

resource "aws_vpc_security_group_ingress_rule" "https_from_vpc" {
  count = var.enabled ? 1 : 0

  security_group_id = aws_security_group.endpoints[0].id
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from the VPC"
}

resource "aws_vpc_endpoint" "interface" {
  for_each = var.enabled ? local.interface_services : toset([])

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true
  tags                = merge(var.tags, { Name = "${var.tags["Environment"]}-pulso-${each.key}" })
}

resource "aws_vpc_endpoint" "s3" {
  count = var.enabled ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.route_table_ids
  tags              = merge(var.tags, { Name = "${var.tags["Environment"]}-pulso-s3" })
}

output "s3_prefix_list_id" {
  value       = var.enabled ? aws_vpc_endpoint.s3[0].prefix_list_id : ""
  description = "Managed prefix list of the S3 gateway endpoint (egress target for ECR layer pulls)."
}

output "endpoint_security_group_id" {
  value = var.enabled ? aws_security_group.endpoints[0].id : ""
}
