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
    error_message = "Two AZs: two public, two private (hosts) and two db subnets."
  }

  assert {
    condition     = alltrue([for s in concat(values(aws_subnet.private), values(aws_subnet.db), values(aws_subnet.public)) : !s.map_public_ip_on_launch])
    error_message = "No subnet assigns public IPs; hosts never get one."
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
    condition     = length(aws_route_table_association.private) == 2
    error_message = "Both private subnets associate with the one NAT route table."
  }
}

run "s3_gateway_endpoint_present" {
  command = plan

  assert {
    condition     = aws_vpc_endpoint.s3.vpc_endpoint_type == "Gateway" && aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "S3 is reached through a free gateway endpoint."
  }
}

run "private_hosted_zone_defaults_to_pulso_internal" {
  command = plan

  assert {
    condition     = aws_route53_zone.internal.name == "pulso.internal" && length(aws_route53_zone.internal.vpc) == 1
    error_message = "A private zone bound to the VPC."
  }
}

run "platform_and_engine_ingress_only_from_cloudfront" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.platform_cloudfront.from_port == 80 && aws_vpc_security_group_ingress_rule.platform_cloudfront.prefix_list_id == "pl-0123456789abcdef0"
    error_message = "Platform :80 from the CloudFront origin-facing prefix list."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.engine_cloudfront.from_port == 8080 && aws_vpc_security_group_ingress_rule.engine_cloudfront.prefix_list_id == "pl-0123456789abcdef0"
    error_message = "Engine :8080 from the CloudFront origin-facing prefix list."
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.admin) == 0 && length(aws_vpc_security_group_ingress_rule.vpc_origin_sg) == 0
    error_message = "No admin or VPC-origin SG ingress by default."
  }
}

run "optional_admin_and_vpc_origin_rules" {
  command = plan

  variables {
    admin_cidr                  = "203.0.113.7/32"
    cloudfront_vpc_origin_sg_id = "sg-0123456789abcdef0"
  }

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.admin) == 2 && length(aws_vpc_security_group_ingress_rule.vpc_origin_sg) == 2
    error_message = "Each option adds one rule per public-facing workload."
  }
}

run "core_8000_only_from_engine_and_platform" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.core_from_engine.from_port == 8000 && aws_vpc_security_group_ingress_rule.core_from_platform.from_port == 8000
    error_message = "Core listens on 8000 for engine and platform."
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.core_from_engine.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.core_from_platform.cidr_ipv4 == null
    error_message = "Sources are security groups, not CIDRs."
  }
}

run "db_accepts_5432_from_the_three_hosts_only" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.db_from) == 3 && alltrue([for r in aws_vpc_security_group_ingress_rule.db_from : r.from_port == 5432 && r.to_port == 5432 && r.cidr_ipv4 == null])
    error_message = "Postgres only, from core, platform and engine SGs."
  }
}

run "egress_is_narrow" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.https) == 3 && alltrue([for r in aws_vpc_security_group_egress_rule.https : r.from_port == 443])
    error_message = "All three hosts may egress on 443 via NAT."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.pg) == 3
    error_message = "All three hosts reach the database."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.to_core) == 2
    error_message = "Only engine and platform call core on 8000."
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.dns) == 6
    error_message = "DNS over udp and tcp for each host."
  }
}

run "no_ssh_anywhere" {
  command = plan

  assert {
    condition     = length([for r in aws_vpc_security_group_ingress_rule.platform_cloudfront : r if r.from_port == 22]) == 0
    error_message = "No SSH."
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
