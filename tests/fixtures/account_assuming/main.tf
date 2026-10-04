# Deliberately bad fixture: every line below must be flagged by scripts/aws_plan_review.py.
provider "aws" {
  region = "us-east-1"
}

variable "bridge_services_enabled" {
  type    = bool
  default = true
}

resource "aws_iam_role" "bad" {
  assume_role_policy = "arn:aws:iam::123456789012:root"
}

resource "aws_iam_role_policy_attachment" "admin" {
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

resource "aws_db_instance" "bad" {
  publicly_accessible = true
}

resource "aws_vpc_security_group_ingress_rule" "open" {
  cidr_ipv4 = "0.0.0.0/0"
}
