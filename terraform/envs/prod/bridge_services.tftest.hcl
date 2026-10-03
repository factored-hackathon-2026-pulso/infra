# Bridge services (core-runtime, core-exporter, platform-exporter): zero diff when off, exact wiring when on.
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
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
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
  core_blob_bucket_name           = "pulso-test-core-blobs"
}

run "defaults_add_nothing" {
  command = plan

  assert {
    condition     = length(module.bridge_services.security_group_ids) == 0 && length(module.bridge_services.task_definition_arns) == 0 && length(module.bridge_services.secret_names) == 0 && module.bridge_services.core_runtime_dns_name == null
    error_message = "bridge_services_enabled=false must add no resource, name or secret."
  }
  assert {
    condition     = length(module.platform_exporter_ecr) == 0
    error_message = "bridge_ecr_enabled=false must add no repository."
  }
}

run "platform_exporter_ecr_reuses_the_shared_ecr_module" {
  command = plan

  variables {
    bridge_ecr_enabled = true
  }

  assert {
    condition     = toset(keys(module.platform_exporter_ecr)) == toset(["pulso-platform-exporter"])
    error_message = "Exactly one repository, from the shared ecr module."
  }
}

run "enabled_wires_the_three_services_to_the_engine_foundation" {
  command = plan

  variables {
    bridge_services_enabled                    = true
    engine_platform_enabled                    = true
    private_endpoints_enabled                  = true
    engine_platform_image                      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    engine_platform_sandbox_image              = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    bridge_core_image                          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso-core@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    bridge_platform_exporter_image             = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso-platform-exporter@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    bridge_core_database_security_group_id     = "sg-0123456789abcdef2"
    bridge_platform_database_security_group_id = "sg-0123456789abcdef3"
    bridge_core_secret_arns = {
      db_app             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf"
      db_exporter        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf"
      identity_keys      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf"
      staff_keys         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf"
      bridge_service_key = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf"
    }
  }

  assert {
    condition     = toset(keys(module.bridge_services.task_definition_arns)) == toset(["core-runtime", "core-exporter", "platform-exporter"]) && module.bridge_services.core_runtime_dns_name == "core-runtime.${local.tags["Environment"]}.pulso.internal"
    error_message = "The three services, Cloud Map name in the namespace engine_platform already owns."
  }
  assert {
    condition     = length(module.bridge_services.secret_names) == 4 && alltrue([for n in values(module.bridge_services.secret_names) : strcontains(n, "/core/") || strcontains(n, "/platform-exporter/")])
    error_message = "Four own secret entries, names only."
  }
}

run "overlapping_engine_wiring_is_refused" {
  command = plan

  variables {
    bridge_services_enabled                          = true
    engine_platform_enabled                          = true
    private_endpoints_enabled                        = true
    engine_platform_image                            = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    engine_platform_sandbox_image                    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    bridge_core_image                                = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso-core@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    bridge_platform_exporter_image                   = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso-platform-exporter@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    bridge_core_database_security_group_id           = "sg-0123456789abcdef2"
    bridge_platform_database_security_group_id       = "sg-0123456789abcdef3"
    engine_platform_core_callback_security_group_ids = ["sg-0123456789abcdef9"]
    bridge_core_secret_arns = {
      db_app             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf"
      db_exporter        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf"
      identity_keys      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf"
      staff_keys         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf"
      bridge_service_key = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf"
    }
  }

  expect_failures = [check.bridge_services_owns_the_engine_flows]
}
