resource "aws_security_group" "workload" {
  name_prefix = "${var.name}-workload-"
  vpc_id      = var.vpc_id
  tags = var.tags
}
resource "aws_security_group" "database" {
  name_prefix = "${var.name}-database-"
  vpc_id      = var.vpc_id
  tags = var.tags
}
resource "aws_vpc_security_group_egress_rule" "workload_https" {
  security_group_id = aws_security_group.workload.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}
resource "aws_vpc_security_group_egress_rule" "workload_to_database" {
  security_group_id            = aws_security_group.workload.id
  referenced_security_group_id = aws_security_group.database.id
  from_port                     = 5432
  to_port                       = 5432
  ip_protocol                   = "tcp"
}
resource "aws_vpc_security_group_ingress_rule" "database_from_workload" {
  security_group_id            = aws_security_group.database.id
  referenced_security_group_id = aws_security_group.workload.id
  from_port                    = 5432
  to_port                      = 5432
  ip_protocol                  = "tcp"
}
