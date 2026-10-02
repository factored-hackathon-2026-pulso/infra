resource "aws_security_group" "runtime" {
  name_prefix = "${var.tags["Environment"]}-pulso-runtime-"
  description = "Pulso runtime: no public ingress; egress is explicit."
  vpc_id      = var.vpc_id

  tags = var.tags
}

resource "aws_security_group" "database" {
  name_prefix = "${var.tags["Environment"]}-pulso-db-"
  description = "Pulso database accepts PostgreSQL only from runtime."
  vpc_id      = var.vpc_id

  tags = var.tags
}

resource "aws_vpc_security_group_egress_rule" "runtime_to_database" {
  security_group_id            = aws_security_group.runtime.id
  referenced_security_group_id = aws_security_group.database.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL only"
}

resource "aws_vpc_security_group_egress_rule" "runtime_https" {
  security_group_id = aws_security_group.runtime.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "AWS APIs and approved external dependencies"
}

resource "aws_vpc_security_group_ingress_rule" "database_from_runtime" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.runtime.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  description                  = "PostgreSQL only from runtime"
}
