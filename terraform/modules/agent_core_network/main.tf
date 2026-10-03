# Security groups of the Agent Core workload (ADR 0003, ADR 0005). The traffic path is
# ALB -> service -> RDS Proxy -> database; nothing else reaches the database.

resource "aws_security_group" "alb" {
  name_prefix = "${var.tags["Environment"]}-agent-core-alb-"
  description = "Agent Core internal load balancer: HTTPS from approved CIDRs only."
  vpc_id      = var.vpc_id
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "service" {
  name_prefix = "${var.tags["Environment"]}-agent-core-svc-"
  description = "Agent Core tasks (serve, relay, sweep, migrate): ingress from the load balancer only."
  vpc_id      = var.vpc_id
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "proxy" {
  name_prefix = "${var.tags["Environment"]}-agent-core-proxy-"
  description = "Agent Core RDS Proxy: PostgreSQL from the tasks only."
  vpc_id      = var.vpc_id
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_security_group" "database" {
  name_prefix = "${var.tags["Environment"]}-agent-core-db-"
  description = "Agent Core database: PostgreSQL from the RDS Proxy only."
  vpc_id      = var.vpc_id
  tags        = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each          = toset(var.ingress_cidrs)
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS from approved internal CIDR"
}

resource "aws_vpc_security_group_egress_rule" "alb_to_service" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.service.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "Forward to Agent Core tasks"
}

resource "aws_vpc_security_group_ingress_rule" "service_from_alb" {
  security_group_id            = aws_security_group.service.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = var.container_port
  to_port                      = var.container_port
  description                  = "From the load balancer only"
}

resource "aws_vpc_security_group_egress_rule" "service_to_proxy" {
  security_group_id            = aws_security_group.service.id
  referenced_security_group_id = aws_security_group.proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL through the RDS Proxy"
}

# controlled_nat profile (ADR 0003 item 6): LLM endpoints, JEV, S3, SNS, Secrets Manager and ECR over HTTPS.
# This is plumbing, not destination control: the destination allow-list is the open
# "Controlled external egress" gap.
resource "aws_vpc_security_group_egress_rule" "service_https" {
  security_group_id = aws_security_group.service.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "AWS APIs and approved external dependencies"
}

resource "aws_vpc_security_group_ingress_rule" "proxy_from_service" {
  security_group_id            = aws_security_group.proxy.id
  referenced_security_group_id = aws_security_group.service.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL from Agent Core tasks"
}

resource "aws_vpc_security_group_egress_rule" "proxy_to_database" {
  security_group_id            = aws_security_group.proxy.id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL to the database"
}

resource "aws_vpc_security_group_ingress_rule" "database_from_proxy" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.proxy.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL only from the RDS Proxy"
}
