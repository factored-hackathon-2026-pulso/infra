# Hackathon network profile (ADR 0007; free_plan variant in ADR 0008: no NAT, hosts in public subnets, no db subnets).
# One VPC, two AZs: public subnets (NAT only), private subnets (the host, no public IP),
# isolated db subnets (no default route). Exactly one NAT gateway, in the first AZ.

locals {
  rds_mode    = var.database_mode == "rds"
  az_suffixes = ["a", "b"]
  azs         = { for i, s in local.az_suffixes : s => { name = "${var.region}${s}", index = i } }
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(var.tags, { Name = var.name })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = var.name })
}

resource "aws_subnet" "public" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.name
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value.index)
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.name}-public-${each.key}", Tier = "public" })
}

resource "aws_subnet" "private" {
  for_each                = local.azs
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.name
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value.index + 10)
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.name}-private-${each.key}", Tier = "private" })
}

resource "aws_subnet" "db" {
  for_each                = local.rds_mode ? local.azs : {}
  vpc_id                  = aws_vpc.this.id
  availability_zone       = each.value.name
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, each.value.index + 20)
  map_public_ip_on_launch = false
  tags                    = merge(var.tags, { Name = "${var.name}-db-${each.key}", Tier = "db" })
}

# Single NAT in one AZ: cheapest option; an AZ-a outage cuts host egress (documented in ADR 0007).
resource "aws_eip" "nat" {
  count  = var.enable_nat ? 1 : 0
  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat" })
}

resource "aws_nat_gateway" "this" {
  count         = var.enable_nat ? 1 : 0
  allocation_id = aws_eip.nat[0].id
  subnet_id     = aws_subnet.public["a"].id
  tags          = merge(var.tags, { Name = var.name })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-public" })
}

resource "aws_route" "public_default" {
  count                  = 1
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-private" })
}

resource "aws_route" "private_default" {
  count                  = var.enable_nat ? 1 : 0
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[0].id
}

# Isolated: local VPC route only; no default route is ever added.
resource "aws_route_table" "db" {
  count  = local.rds_mode ? 1 : 0
  vpc_id = aws_vpc.this.id
  tags   = merge(var.tags, { Name = "${var.name}-db" })
}

resource "aws_route" "db_default" {
  count                  = 0
  route_table_id         = one(aws_route_table.db[*].id)
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = one(aws_nat_gateway.this[*].id)
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_route_table_association" "db" {
  for_each       = aws_subnet.db
  subnet_id      = each.value.id
  route_table_id = one(aws_route_table.db[*].id)
}

# Free gateway endpoint: keeps S3 traffic off the NAT (no per-GB NAT processing charge).
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id, aws_route_table.public.id]
  tags              = merge(var.tags, { Name = "${var.name}-s3" })
}

# One security group per workload (ADR 0007): core, platform, engine, plus the database.
locals {
  workloads = toset(["core", "platform", "engine"])
  # Ports CloudFront reaches on the two public-facing workloads.
  edge_ports = { platform = 80, engine = 8080 }
}

resource "aws_security_group" "core" {
  name_prefix = "${var.name}-core-"
  description = "Agent-core host (core and llm-gateway): 8000 from engine and platform only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-core" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "platform" {
  name_prefix = "${var.name}-platform-"
  description = "Support-platform host: 80 from CloudFront only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-platform" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "engine" {
  name_prefix = "${var.name}-engine-"
  description = "Engine host (pulso): 8080 from CloudFront only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-engine" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "db" {
  count       = local.rds_mode ? 1 : 0
  name_prefix = "${var.name}-db-"
  description = "Database: 5432 from the three hosts only"
  vpc_id      = aws_vpc.this.id
  tags        = merge(var.tags, { Name = "${var.name}-db" })

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  sg_ids = {
    core     = aws_security_group.core.id
    platform = aws_security_group.platform.id
    engine   = aws_security_group.engine.id
  }
}

resource "aws_vpc_security_group_ingress_rule" "platform_cloudfront" {
  security_group_id = aws_security_group.platform.id
  description       = "CloudFront origin-facing prefix list"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "engine_cloudfront" {
  security_group_id = aws_security_group.engine.id
  description       = "CloudFront origin-facing prefix list"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = 8080
  to_port           = 8080
}

resource "aws_vpc_security_group_ingress_rule" "vpc_origin_sg" {
  for_each                     = var.cloudfront_vpc_origin_sg_id == "" ? toset([]) : toset(["platform", "engine"])
  security_group_id            = local.sg_ids[each.key]
  description                  = "CloudFront VPC origin service SG"
  referenced_security_group_id = var.cloudfront_vpc_origin_sg_id
  ip_protocol                  = "tcp"
  from_port                    = local.edge_ports[each.key]
  to_port                      = local.edge_ports[each.key]
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  for_each          = var.admin_cidr == "" ? toset([]) : toset(["platform", "engine"])
  security_group_id = local.sg_ids[each.key]
  description       = "Optional admin CIDR"
  cidr_ipv4         = var.admin_cidr
  ip_protocol       = "tcp"
  from_port         = local.edge_ports[each.key]
  to_port           = local.edge_ports[each.key]
}

resource "aws_vpc_security_group_ingress_rule" "core_from_engine" {
  security_group_id            = aws_security_group.core.id
  description                  = "Core API from engine"
  referenced_security_group_id = aws_security_group.engine.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_ingress_rule" "core_from_platform" {
  security_group_id            = aws_security_group.core.id
  description                  = "Core API from support-platform"
  referenced_security_group_id = aws_security_group.platform.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

resource "aws_vpc_security_group_ingress_rule" "db_from" {
  for_each                     = local.rds_mode ? local.workloads : toset([])
  security_group_id            = one(aws_security_group.db[*].id)
  description                  = "Postgres from ${each.key}"
  referenced_security_group_id = local.sg_ids[each.key]
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "https" {
  for_each          = local.workloads
  security_group_id = local.sg_ids[each.key]
  description       = "HTTPS out (ECR, SSM, model APIs) via NAT, or the public IP without NAT; S3 uses the gateway endpoint"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "pg" {
  for_each                     = local.rds_mode ? local.workloads : toset([])
  security_group_id            = local.sg_ids[each.key]
  description                  = "Postgres to the database SG"
  referenced_security_group_id = one(aws_security_group.db[*].id)
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

# Container database mode: Postgres runs on the core host; the sibling hosts reach it through the core SG.
resource "aws_vpc_security_group_ingress_rule" "core_pg_from" {
  for_each                     = local.rds_mode ? toset([]) : toset(["platform", "engine"])
  security_group_id            = aws_security_group.core.id
  description                  = "Postgres container on the core host, from ${each.key}"
  referenced_security_group_id = local.sg_ids[each.key]
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "pg_to_core" {
  for_each                     = local.rds_mode ? toset([]) : toset(["platform", "engine"])
  security_group_id            = local.sg_ids[each.key]
  description                  = "Postgres container on the core host"
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "to_core" {
  for_each                     = toset(["platform", "engine"])
  security_group_id            = local.sg_ids[each.key]
  description                  = "Core API"
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 8000
  to_port                      = 8000
}

# llm-gateway (core host :8080): the engine host calls it with its own bearer token (consumer ENGINE). The platform is a
# gateway consumer too (SUPPORT_PLATFORM) but has no gateway path in this change; open it by adding "platform" below.
resource "aws_vpc_security_group_ingress_rule" "gateway_from" {
  for_each                     = toset(["engine"])
  security_group_id            = aws_security_group.core.id
  description                  = "llm-gateway on the core host, from ${each.key}"
  referenced_security_group_id = local.sg_ids[each.key]
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "to_gateway" {
  for_each                     = toset(["engine"])
  security_group_id            = local.sg_ids[each.key]
  description                  = "llm-gateway on the core host"
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

# Platform internal listener (:8081, only /api/v1/internal/grants/*): agent-core's grant_active check from the core host.
resource "aws_vpc_security_group_ingress_rule" "platform_internal_from_core" {
  security_group_id            = aws_security_group.platform.id
  description                  = "Grant check (internal listener) from the core host"
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
}

resource "aws_vpc_security_group_egress_rule" "core_to_platform_internal" {
  security_group_id            = aws_security_group.core.id
  description                  = "Grant check on the platform internal listener"
  referenced_security_group_id = aws_security_group.platform.id
  ip_protocol                  = "tcp"
  from_port                    = 8081
  to_port                      = 8081
}

resource "aws_vpc_security_group_egress_rule" "dns" {
  for_each          = { for p in setproduct(local.workloads, ["tcp", "udp"]) : "${p[0]}-${p[1]}" => { sg = p[0], proto = p[1] } }
  security_group_id = local.sg_ids[each.value.sg]
  description       = "DNS to the VPC resolver"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = each.value.proto
  from_port         = 53
  to_port           = 53
}

# Private zone for service discovery between hosts; the compute lane creates the records.
resource "aws_route53_zone" "internal" {
  name = var.zone_name
  tags = merge(var.tags, { Name = var.zone_name })

  vpc {
    vpc_id = aws_vpc.this.id
  }
}

resource "aws_cloudwatch_log_group" "flow" {
  count             = var.enable_flow_logs ? 1 : 0
  name              = "/${var.name}/vpc-flow"
  retention_in_days = var.flow_logs_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "flow_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "flow" {
  count              = var.enable_flow_logs ? 1 : 0
  name_prefix        = "${var.name}-flow-"
  assume_role_policy = data.aws_iam_policy_document.flow_assume.json
  tags               = var.tags
}

data "aws_iam_policy_document" "flow_write" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["arn:aws:logs:${var.region}:*:log-group:/${var.name}/vpc-flow:*"]
  }
}

resource "aws_iam_role_policy" "flow" {
  count  = var.enable_flow_logs ? 1 : 0
  name   = "write-flow-logs"
  role   = aws_iam_role.flow[0].id
  policy = data.aws_iam_policy_document.flow_write.json
}

resource "aws_flow_log" "this" {
  count           = var.enable_flow_logs ? 1 : 0
  vpc_id          = aws_vpc.this.id
  traffic_type    = "ALL"
  log_destination = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn    = aws_iam_role.flow[0].arn
  tags            = var.tags
}
