mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = {
      id = "pl-0123456789abcdef0"
    }
  }
}

variables {
  name   = "hk"
  region = "us-east-1"
  tags   = { Environment = "hackathon" }
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
    condition     = length([for r in [aws_vpc_security_group_ingress_rule.platform_cloudfront, aws_vpc_security_group_ingress_rule.engine_cloudfront] : r if r.from_port == 22]) == 0
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

# ---- free_plan profile: no NAT gateway, hosts in public subnets, database on the core host ----

run "free_plan_has_no_nat_and_hosts_use_public_subnets" {
  command = plan
  variables {
    enable_nat    = false
    database_mode = "container"
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0 && length(aws_eip.nat) == 0 && length(aws_route.private_default) == 0
    error_message = "enable_nat=false removes the NAT gateway, its EIP and the private default route."
  }
  assert {
    condition     = length(output.host_subnet_ids) == 2 && output.hosts_get_public_ip
    error_message = "Without NAT the hosts live in the public subnets (public IP, outbound-only SG)."
  }
  assert {
    condition     = length(aws_route.public_default) == 1
    error_message = "Public subnets keep the internet gateway default route."
  }
}

run "container_database_drops_isolated_subnets_and_db_sg" {
  command = plan
  variables {
    enable_nat    = false
    database_mode = "container"
  }

  assert {
    condition     = length(aws_subnet.db) == 0 && length(aws_security_group.db) == 0 && length(aws_route_table.db) == 0
    error_message = "Isolated db subnets and the db SG exist only in rds mode."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.core_pg_from) == 2
    error_message = "Core accepts 5432 from the platform and engine SGs only (sibling SGs)."
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.pg_to_core) == 2
    error_message = "Platform and engine may egress 5432 to the core SG."
  }
  assert {
    condition     = aws_vpc_security_group_ingress_rule.platform_cloudfront.prefix_list_id != null && aws_vpc_security_group_ingress_rule.engine_cloudfront.prefix_list_id != null
    error_message = "Proxies stay reachable only from the CloudFront origin-facing prefix list."
  }
}

run "s3_endpoint_covers_public_route_table_without_nat" {
  command = apply
  variables {
    enable_nat    = false
    database_mode = "container"
  }

  assert {
    condition     = length(aws_vpc_endpoint.s3.route_table_ids) == 2
    error_message = "Hosts in public subnets reach S3 through the gateway endpoint as well."
  }
}

run "rds_mode_keeps_the_previous_design" {
  command = apply

  assert {
    condition     = length(aws_subnet.db) == 2 && length(aws_security_group.db) == 1 && length(aws_vpc_security_group_ingress_rule.core_pg_from) == 0
    error_message = "Defaults (nat, rds) are the previous prod design."
  }
}

run "gateway_8080_only_from_engine" {
  command = plan

  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.gateway_from) == 1 && aws_vpc_security_group_ingress_rule.gateway_from["engine"].from_port == 8080 && aws_vpc_security_group_ingress_rule.gateway_from["engine"].to_port == 8080 && aws_vpc_security_group_ingress_rule.gateway_from["engine"].cidr_ipv4 == null
    error_message = "The llm-gateway port is open on the core SG from the engine SG only."
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.to_gateway) == 1 && aws_vpc_security_group_egress_rule.to_gateway["engine"].from_port == 8080
    error_message = "The engine may egress 8080 to the core SG."
  }
}

run "platform_internal_listener_only_from_core" {
  command = plan

  assert {
    condition     = aws_vpc_security_group_ingress_rule.platform_internal_from_core.from_port == 8081 && aws_vpc_security_group_ingress_rule.platform_internal_from_core.to_port == 8081 && aws_vpc_security_group_ingress_rule.platform_internal_from_core.cidr_ipv4 == null && aws_vpc_security_group_ingress_rule.platform_internal_from_core.prefix_list_id == null
    error_message = "The platform internal listener accepts 8081 from the core SG only."
  }
  assert {
    condition     = aws_vpc_security_group_egress_rule.core_to_platform_internal.from_port == 8081
    error_message = "The core host may egress 8081 to the platform SG."
  }
}
