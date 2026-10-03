# Engine platform and shared endpoints: zero diff when off, exact resource set when on.
mock_provider "aws" {
  mock_resource "aws_vpc_endpoint" {
    defaults = {
      prefix_list_id = "pl-0123456789abcdef0"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:engine-test"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-role"
    }
  }
  mock_resource "aws_ecs_task_definition" {
    defaults = {
      arn = "arn:aws:ecs:us-east-1:123456789012:task-definition/mock:1"
    }
  }
  mock_resource "aws_service_discovery_service" {
    defaults = {
      arn = "arn:aws:servicediscovery:us-east-1:123456789012:service/srv-mock"
    }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

variables {
  aws_region                      = "us-east-1"
  vpc_cidr                        = "10.20.0.0/16"
  public_subnet_cidrs             = ["10.20.0.0/24", "10.20.1.0/24"]
  private_subnet_cidrs            = ["10.20.10.0/24", "10.20.11.0/24"]
  availability_zones              = ["us-east-1a", "us-east-1b"]
  nat_strategy                    = "single"
  least_privilege_policy_boundary = ""
  image_digest                    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/improvement-engine@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  artifact_bucket_name            = "pulso-test-artifacts"
  source_bucket_name              = "pulso-test-sources"
  database_engine                 = "postgres"
  secret_name_prefix              = "pulso/test"
  kms_key_arn                     = ""
  runtime_database_secret_arn     = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-runtime-db-test"
  desired_count                   = 0
  database_instance_class         = "db.t4g.micro"
  database_backup_retention_days  = 7
  database_deletion_protection    = false
  database_skip_final_snapshot    = true
  database_multi_az               = false
  log_retention_days              = 14
  alarm_actions                   = []
}

run "defaults_add_nothing" {
  command = plan

  assert {
    condition     = length(module.engine_platform.security_group_ids) == 0 && length(module.engine_platform.task_definition_arns) == 0 && length(module.engine_platform.secret_names) == 0 && module.engine_platform.control_api_dns_name == null && module.engine_platform.service_discovery_namespace_id == ""
    error_message = "engine_platform_enabled=false must add no resource, name or namespace."
  }
  assert {
    condition     = module.private_endpoints.s3_prefix_list_id == "" && module.private_endpoints.endpoint_security_group_id == ""
    error_message = "private_endpoints_enabled=false must add no VPC endpoint."
  }
}

run "enabled_declares_the_engine_resource_set_on_the_shared_foundations" {
  command = plan

  variables {
    engine_platform_enabled       = true
    private_endpoints_enabled     = true
    engine_platform_image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    engine_platform_sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = toset(keys(module.engine_platform.security_group_ids)) == toset(["control-api", "worker", "migrate", "sandbox-lab"]) && toset(keys(module.engine_platform.task_definition_arns)) == toset(["control-api", "worker", "migrate", "sandbox-lab"])
    error_message = "Exactly four engine workloads; no human-issuer, no console, no load balancer."
  }
  assert {
    condition     = module.engine_platform.control_api_dns_name == "control-api.${local.tags["Environment"]}.pulso.internal"
    error_message = "control-api is reached by Cloud Map private DNS."
  }
  assert {
    condition     = length(module.engine_platform.secret_names) == 6 && alltrue([for n in values(module.engine_platform.secret_names) : strcontains(n, "/engine/")])
    error_message = "Six per-workload secret entries, names only."
  }
}

run "enabled_state_holds_no_secret_value" {
  command = apply

  variables {
    engine_platform_enabled       = true
    private_endpoints_enabled     = true
    engine_platform_image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    engine_platform_sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = !strcontains(jsonencode(module.engine_platform.secret_names), "secret_string") && module.private_endpoints.s3_prefix_list_id != ""
    error_message = "Outputs carry names only; the S3 prefix list is wired from the shared endpoints."
  }
}
