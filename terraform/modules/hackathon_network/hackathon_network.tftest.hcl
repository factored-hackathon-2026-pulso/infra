mock_provider "aws" {
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = {
      id = "pl-0123456789abcdef0"
    }
  }
}

variables {
  name = "hk"
  tags = { Environment = "hackathon" }
}

run "two_az_public_private_and_isolated_db_subnets" {
  command = plan

  assert {
    condition     = length(aws_subnet.public) == 2 && length(aws_subnet.private) == 2 && length(aws_subnet.db) == 2
    error_message = "Two AZs: two public, two private (host) and two db subnets."
  }

  assert {
    condition     = alltrue([for s in concat(values(aws_subnet.private), values(aws_subnet.db)) : !s.map_public_ip_on_launch])
    error_message = "Host and db subnets never assign public IPs."
  }
}

run "single_nat_gateway_in_one_az" {
  command = plan

  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "Exactly one NAT gateway and one EIP."
  }

  assert {
    condition     = length(aws_route.private_default) == 1 && length(aws_route.public_default) == 1 && length(aws_route.db_default) == 0
    error_message = "Private and public tables have a default route; db has none."
  }

  assert {
    condition     = aws_route_table_association.private["a"].route_table_id == aws_route_table_association.private["b"].route_table_id
    error_message = "Both private subnets share the single-NAT route table."
  }
}

run "s3_gateway_endpoint_present" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "S3 is reached through a free gateway endpoint."
  }
}

run "host_ingress_only_from_cloudfront_prefix_list" {
  command = plan

  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.host_cloudfront : r.prefix_list_id == "pl-0123456789abcdef0"]) && length(aws_vpc_security_group_ingress_rule.host_cloudfront) == 2
    error_message = "Ports 80 and 443 are open only to the CloudFront origin-facing prefix list."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.host_admin) == 0 && length(aws_vpc_security_group_ingress_rule.host_vpc_origin_sg) == 0
    error_message = "No admin or VPC-origin SG ingress by default."
  }

  assert {
    condition     = length([for r in aws_vpc_security_group_ingress_rule.host_cloudfront : r if r.from_port == 22]) == 0
    error_message = "No SSH."
  }
}

run "admin_cidr_opens_only_when_set" {
  command = plan

  variables {
    admin_cidr = "203.0.113.7/32"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.host_admin) == 1
    error_message = "A set admin CIDR adds one rule."
  }
}

run "vpc_origin_sg_adds_ingress_rules" {
  command = plan

  variables {
    cloudfront_vpc_origin_sg_id = "sg-0123456789abcdef0"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.host_vpc_origin_sg) == 2
    error_message = "VPC origin service SG gets 80 and 443."
  }
}

run "db_accepts_5432_only_from_host_sg" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_host.from_port == 5432 && aws_vpc_security_group_ingress_rule.db_from_host.to_port == 5432
    error_message = "Postgres only."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.db_from_host.cidr_ipv4 == null
    error_message = "Source is the host SG, not a CIDR."
  }
}

run "host_egress_is_narrow" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_egress_rule.host_https.from_port == 443 && aws_vpc_security_group_egress_rule.host_pg.from_port == 5432
    error_message = "Egress limited to 443 and 5432."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.host_dns) == 2
    error_message = "DNS over udp and tcp."
  }
}

run "flow_logs_off_by_default" {
  command = plan

  assert {
    condition     = length(aws_flow_log.this) == 0
    error_message = "Flow logs cost money; default off."
  }
}

run "flow_logs_toggle" {
  command = plan

  variables {
    enable_flow_logs = true
  }

  assert {
    condition     = length(aws_flow_log.this) == 1
    error_message = "Toggle creates the flow log."
  }
}
