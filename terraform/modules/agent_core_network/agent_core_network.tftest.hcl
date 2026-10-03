mock_provider "aws" {}

variables {
  vpc_id        = "vpc-0123456789abcdef0"
  ingress_cidrs = ["10.0.0.0/16"]
  tags          = { Environment = "test" }
}

run "internal_cidr_is_accepted_and_opens_only_443" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.alb_https["10.0.0.0/16"].from_port == 443 && aws_vpc_security_group_ingress_rule.alb_https["10.0.0.0/16"].to_port == 443
    error_message = "The load balancer must accept HTTPS only."
  }
}

run "the_whole_internet_is_rejected" {
  command = plan

  variables {
    ingress_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [var.ingress_cidrs]
}

run "an_invalid_cidr_is_rejected" {
  command = plan

  variables {
    ingress_cidrs = ["not-a-cidr"]
  }

  expect_failures = [var.ingress_cidrs]
}

run "database_accepts_postgres_only_from_the_proxy" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.database_from_proxy.from_port == 5432 && aws_vpc_security_group_ingress_rule.database_from_proxy.to_port == 5432
    error_message = "The database port must be PostgreSQL only."
  }
}
