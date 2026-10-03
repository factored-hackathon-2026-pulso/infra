mock_provider "aws" {
  mock_resource "aws_vpc_endpoint" {
    defaults = {
      prefix_list_id = "pl-0123456789abcdef0"
    }
  }
}

variables {
  aws_region          = "us-east-1"
  vpc_id              = "vpc-0123456789abcdef0"
  vpc_cidr            = "10.20.0.0/16"
  subnet_ids          = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  route_table_ids     = ["rtb-0123456789abcdef0", "rtb-0123456789abcdef1"]
  customer_kms_in_use = true
  tags                = { Environment = "test" }
}

run "disabled_by_default_declares_nothing" {
  command = plan

  assert {
    condition     = length(aws_vpc_endpoint.interface) == 0 && length(aws_vpc_endpoint.s3) == 0 && length(aws_security_group.endpoints) == 0
    error_message = "enabled=false must plan zero resources (zero diff for existing environments)."
  }
  assert {
    condition     = output.s3_prefix_list_id == "" && output.endpoint_security_group_id == ""
    error_message = "A disabled module publishes empty ids."
  }
}

run "enabled_declares_the_aws_api_endpoints_core_tasks_need" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = toset(keys(aws_vpc_endpoint.interface)) == toset(["ecr.api", "ecr.dkr", "secretsmanager", "logs", "kms"])
    error_message = "ECR API/DKR, Secrets Manager, CloudWatch Logs and KMS interface endpoints."
  }
  assert {
    condition     = alltrue([for e in values(aws_vpc_endpoint.interface) : e.vpc_endpoint_type == "Interface" && e.private_dns_enabled])
    error_message = "Interface endpoints use private DNS so the default AWS hostnames resolve privately."
  }
  assert {
    condition     = length(aws_vpc_endpoint.s3) == 1 && aws_vpc_endpoint.s3[0].vpc_endpoint_type == "Gateway" && length(aws_vpc_endpoint.s3[0].route_table_ids) == 2
    error_message = "ECR layers are served from S3: a gateway endpoint on every private route table."
  }
}

run "kms_endpoint_only_with_a_customer_managed_key" {
  command = plan

  variables {
    enabled             = true
    customer_kms_in_use = false
  }

  assert {
    condition     = !contains(keys(aws_vpc_endpoint.interface), "kms")
    error_message = "Without a customer-managed key no KMS endpoint is needed."
  }
}

run "endpoint_security_group_accepts_only_vpc_https" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = aws_vpc_security_group_ingress_rule.https_from_vpc[0].cidr_ipv4 == "10.20.0.0/16" && aws_vpc_security_group_ingress_rule.https_from_vpc[0].from_port == 443 && aws_vpc_security_group_ingress_rule.https_from_vpc[0].to_port == 443
    error_message = "Endpoints accept TCP/443 from the VPC CIDR only."
  }
}

run "ecs_api_endpoint_only_when_tasks_launch_tasks" {
  command = plan

  variables {
    enabled = true
    ecs_api = true
  }

  assert {
    condition     = contains(keys(aws_vpc_endpoint.interface), "ecs") && length(aws_vpc_endpoint.interface) == 6
    error_message = "A worker that calls ecs:RunTask without NAT needs the ECS API endpoint."
  }
}

run "ecs_api_endpoint_is_off_by_default" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = !contains(keys(aws_vpc_endpoint.interface), "ecs")
    error_message = "No ECS endpoint unless asked for (billed per AZ-hour)."
  }
}
