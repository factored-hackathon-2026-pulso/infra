mock_provider "aws" {
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf"
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

# Every input is valid and complete; only `enabled` is off. Runs flip it and override what they test.
variables {
  enabled                             = false
  aws_region                          = "us-east-1"
  vpc_id                              = "vpc-0123456789abcdef0"
  vpc_cidr                            = "10.20.0.0/16"
  private_subnet_ids                  = ["subnet-0123456789abcdef0"]
  cluster_arn                         = "arn:aws:ecs:us-east-1:123456789012:cluster/test-pulso"
  rds_master_secret_arn_guard         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  secret_name_prefix                  = "pulso/test"
  log_retention_days                  = 14
  tags                                = { Environment = "test" }
  core_image                          = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test/pulso-core@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  platform_exporter_image             = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test/pulso-platform-exporter@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  service_discovery_namespace_id      = "ns-0123456789abcdef0"
  control_api_security_group_id       = "sg-0123456789abcdef1"
  control_api_dns_name                = "control-api.test.pulso.internal"
  engine_caller_security_group_ids    = { control-api = "sg-0123456789abcdef1", worker = "sg-0123456789abcdef4" }
  core_database_security_group_id     = "sg-0123456789abcdef2"
  platform_database_security_group_id = "sg-0123456789abcdef3"
  llm_gateway_url                     = "http://llm-gateway.test.pulso.internal:8080"
  llm_gateway_security_group_id       = "sg-0123456789abcdef5"
  s3_egress_enabled                   = true
  s3_prefix_list_id                   = "pl-0123456789abcdef0"
  tenant_id                           = "tenant-test"
  core_instance                       = "core-test"
  exporter_binding_ref                = "binding-test"
  expected_runtime_db                 = "core_runtime"
  expected_eval_db                    = "core_eval"
  platform_instance                   = "platform-test"
  platform_binding_ref                = "binding-platform-test"
  core_secret_arns = {
    db_app             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf"
    db_exporter        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf"
    identity_keys      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf"
    staff_keys         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf"
    bridge_service_key = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf"
    llm_gateway_token  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-llm-gateway-token-AbCdEf"
  }
}

run "disabled_by_default_plans_zero_resources" {
  command = plan

  assert {
    condition     = length(aws_security_group.bridge) == 0 && length(module.workload) == 0 && length(module.iam) == 0 && length(aws_cloudwatch_log_group.bridge) == 0 && length(aws_secretsmanager_secret.this) == 0
    error_message = "enabled=false must declare nothing."
  }
  assert {
    condition     = length(aws_service_discovery_service.core_runtime) == 0 && length(aws_vpc_security_group_egress_rule.to_control_api) == 0 && length(aws_vpc_security_group_ingress_rule.control_api_from_bridge) == 0
    error_message = "enabled=false must declare no Cloud Map service or security-group rule."
  }
  assert {
    condition     = output.core_runtime_dns_name == null && length(output.security_group_ids) == 0 && length(output.task_definition_arns) == 0
    error_message = "enabled=false publishes nothing."
  }
}

run "enabled_requires_digest_images" {
  command = plan

  variables {
    enabled    = true
    core_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/test/pulso-core:latest"
  }

  expect_failures = [var.core_image]
}

run "enabled_declares_runtime_core_exporter_and_platform_exporter_only" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = toset(keys(output.task_definition_arns)) == toset(["core-runtime", "core-exporter", "platform-exporter"]) && toset(keys(output.security_group_ids)) == toset(["core-runtime", "core-exporter", "platform-exporter"])
    error_message = "Exactly the three services we own; no migrate, sweep, gateway or Core database."
  }
  assert {
    condition     = toset(values(output.secret_names)) == toset(["pulso/test/core/bridge-signers", "pulso/test/core/exporter-keys", "pulso/test/platform-exporter/db-readonly", "pulso/test/platform-exporter/keys"])
    error_message = "Only our four own secret entries are created (names only); Core's core/* entries are consumed by ARN."
  }
  assert {
    condition     = output.core_runtime_dns_name == "core-runtime.test.pulso.internal" && aws_service_discovery_service.core_runtime[0].dns_config[0].namespace_id == "ns-0123456789abcdef0"
    error_message = "core-runtime is registered in the shared <env>.pulso.internal namespace; no second namespace."
  }
  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.to_database)) == toset(["core-runtime", "core-exporter", "platform-exporter"]) && aws_vpc_security_group_egress_rule.to_database["platform-exporter"].referenced_security_group_id == "sg-0123456789abcdef3" && aws_vpc_security_group_egress_rule.to_database["core-exporter"].referenced_security_group_id == "sg-0123456789abcdef2" && aws_vpc_security_group_egress_rule.to_database["core-runtime"].referenced_security_group_id == "sg-0123456789abcdef2"
    error_message = "Core runtime and exporter reach only the Core database; the platform exporter reaches only the platform database."
  }
  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.control_api_from_bridge)) == toset(["core-runtime", "core-exporter", "platform-exporter"]) && toset(keys(aws_vpc_security_group_ingress_rule.runtime_from_engine)) == toset(["control-api", "worker"]) && toset(keys(aws_vpc_security_group_egress_rule.engine_to_runtime)) == toset(["control-api", "worker"])
    error_message = "F1 (both ends), F2 and F3 are opened by security-group reference only."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.database_from_bridge) == 0
    error_message = "Opening a foreign database security group is opt-in (the Core workload slice or the platform owns it)."
  }
}

run "task_definitions_carry_names_only_and_a_read_only_root_with_ephemeral_key_storage" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = toset(output.secret_variable_names["core-runtime"]) == toset(["AGENTCORE_EVAL_DSN", "AGENTCORE_LLM_GATEWAY_TOKEN", "AGENTCORE_REGISTRY_DSN", "CORE_IDENTITY_KEYS_JSON", "CORE_STAFF_KEYS_JSON", "PULSO_BRIDGE_CALLBACK_SIGNER_JSON", "PULSO_BRIDGE_EXECUTOR_SIGNER_JSON", "PULSO_BRIDGE_IDENTITY_SIGNER_JSON", "PULSO_BRIDGE_STAFF_SIGNER_JSON", "PULSO_SERVICE_KEYS_JSON"])
    error_message = "The runtime injects exactly the ADR 0009 / delta-spec secret variables."
  }
  assert {
    condition     = toset(output.secret_variable_names["core-exporter"]) == toset(["CORE_EXPORT_DATABASE_URL", "PULSO_EXPORTER_KEY_CONTROL_API_SEED", "PULSO_EXPORTER_KEY_LAB_BROKER_SEED"]) && toset(output.secret_variable_names["platform-exporter"]) == toset(["PLATFORM_DB_URL", "PULSO_EXPORTER_KEY_CONTROL_API_SEED", "PULSO_EXPORTER_KEY_LAB_BROKER_SEED"])
    error_message = "Exporters get their read-only database credential and their signing seeds only."
  }
  assert {
    condition     = alltrue([for k, names in output.secret_variable_names : !contains(names, "AGENTCORE_ALLOW_DEMO") && !contains(names, "AGENTCORE_JEV_API_KEY") && !contains(names, "LLM_ENDPOINTS") && !contains(names, "PULSO_SERVICE_TOKEN")])
    error_message = "No demo flag, JEV key, provider endpoint or static bearer token reaches any workload."
  }
  assert {
    condition     = alltrue([for k, w in output.container_settings : w.read_only_root_filesystem && contains(values(w.ephemeral_volumes), "/run/pulso-keys")])
    error_message = "Every workload has a read-only root and a writable ephemeral volume at /run/pulso-keys (ADR 0009)."
  }
  assert {
    condition     = contains(values(output.container_settings["core-exporter"].ephemeral_volumes), "/var/lib/pulso-exporter") && contains(values(output.container_settings["platform-exporter"].ephemeral_volumes), "/var/lib/pulso-platform-exporter") && output.container_settings["core-exporter"].port == null && output.container_settings["platform-exporter"].port == null && output.container_settings["core-runtime"].port == 8000
    error_message = "Exporter cursors live on ephemeral task storage (restart replays from the rescan); only the runtime listens."
  }
  assert {
    condition     = output.container_settings["core-runtime"].command == ["runtime"] && output.container_settings["core-exporter"].command == ["exporter"] && output.container_settings["platform-exporter"].command == null
    error_message = "One Core image serves the runtime and exporter roles through its entrypoint argument."
  }
  assert {
    condition     = output.container_settings["core-runtime"].environment["PULSO_CONTROL_API_URL"] == "http://control-api.test.pulso.internal:8080" && output.container_settings["core-runtime"].environment["PULSO_LAB_BROKER_URL"] == "http://control-api.test.pulso.internal:8080" && output.container_settings["core-exporter"].environment["PULSO_INGEST_BASE_URL"] == "http://control-api.test.pulso.internal:8080" && output.container_settings["platform-exporter"].environment["PULSO_CONTROL_API_URL"] == "http://control-api.test.pulso.internal:8080"
    error_message = "Callbacks, lab-broker and ingest all use the engine control-api private DNS name."
  }
}

run "execution_roles_read_only_their_own_secrets" {
  command = apply

  variables {
    enabled = true
  }

  assert {
    condition     = length(output.execution_secret_arns["core-runtime"]) == 6 && length(output.execution_secret_arns["core-exporter"]) == 2 && length(output.execution_secret_arns["platform-exporter"]) == 2
    error_message = "Runtime: 5 Core secrets plus bridge-signers; core-exporter: db-exporter plus exporter-keys; platform-exporter: its two own secrets."
  }
  assert {
    condition     = !contains(output.execution_secret_arns["core-exporter"], "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf") && !contains(output.execution_secret_arns["platform-exporter"], "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf")
    error_message = "The exporters can never resolve the application DSN, and the platform exporter never a Core credential."
  }
}

run "database_opening_is_opt_in" {
  command = plan

  variables {
    enabled                          = true
    manage_core_database_ingress     = true
    manage_platform_database_ingress = true
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.database_from_bridge)) == toset(["core-runtime", "core-exporter", "platform-exporter"])
    error_message = "With the switches on, each service is admitted on its own database security group only."
  }
}

run "a_missing_database_security_group_fails_closed" {
  command = plan

  variables {
    enabled                         = true
    core_database_security_group_id = ""
  }

  expect_failures = [aws_security_group.bridge]
}

run "the_rds_master_secret_cannot_be_a_core_secret_input" {
  command = plan

  variables {
    enabled = true
    core_secret_arns = {
      db_app             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
      db_exporter        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf"
      identity_keys      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf"
      staff_keys         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf"
      bridge_service_key = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf"
      llm_gateway_token  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-llm-gateway-token-AbCdEf"
    }
  }

  expect_failures = [var.core_secret_arns]
}

run "runtime_with_a_gateway_url_but_no_token_fails_closed" {
  command = plan

  variables {
    enabled                   = true
    platform_exporter_enabled = false
    core_exporter_enabled     = false
    core_secret_arns = {
      db_app             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf"
      identity_keys      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf"
      staff_keys         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf"
      bridge_service_key = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf"
    }
  }

  expect_failures = [aws_security_group.bridge]
}

run "individual_services_can_be_left_out" {
  command = plan

  variables {
    enabled               = true
    core_runtime_enabled  = false
    core_exporter_enabled = false
    core_image            = ""
    core_secret_arns      = {}
  }

  assert {
    condition     = toset(keys(output.task_definition_arns)) == toset(["platform-exporter"]) && length(aws_service_discovery_service.core_runtime) == 0 && length(aws_secretsmanager_secret.this) == 2
    error_message = "A platform-exporter-only plan declares one service, its two secrets and no Cloud Map name."
  }
}

# Review additions: assertions on what is really rendered (task definitions, rules), not on module-local literals.
# The mock gives every secret this module creates the same ARN, so own-secret wiring is pinned by JSON key and by set.
run "rendered_task_definitions_wire_each_variable_to_exactly_its_own_secret" {
  command = apply

  variables {
    enabled = true
  }


  assert {
    condition = (
      output.rendered_secrets["core-runtime"]["AGENTCORE_REGISTRY_DSN"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf:registry_dsn::" &&
      output.rendered_secrets["core-runtime"]["AGENTCORE_EVAL_DSN"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf:eval_dsn::" &&
      output.rendered_secrets["core-runtime"]["CORE_IDENTITY_KEYS_JSON"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf" &&
      output.rendered_secrets["core-runtime"]["CORE_STAFF_KEYS_JSON"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf" &&
      output.rendered_secrets["core-runtime"]["PULSO_SERVICE_KEYS_JSON"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf" &&
      output.rendered_secrets["core-runtime"]["AGENTCORE_LLM_GATEWAY_TOKEN"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-llm-gateway-token-AbCdEf"
    )
    error_message = "Each Core secret variable of the runtime must resolve to its own Core secret (db-app by JSON key)."
  }
  assert {
    condition = (
      output.rendered_secrets["core-runtime"]["PULSO_BRIDGE_IDENTITY_SIGNER_JSON"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf:identity::" &&
      output.rendered_secrets["core-runtime"]["PULSO_BRIDGE_STAFF_SIGNER_JSON"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf:staff::" &&
      output.rendered_secrets["core-runtime"]["PULSO_BRIDGE_CALLBACK_SIGNER_JSON"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf:callback::" &&
      output.rendered_secrets["core-runtime"]["PULSO_BRIDGE_EXECUTOR_SIGNER_JSON"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf:executor::"
    )
    error_message = "The four bridge signers are four distinct JSON keys of core/bridge-signers (callback and executor must differ)."
  }
  assert {
    condition = (
      output.rendered_secrets["core-exporter"]["CORE_EXPORT_DATABASE_URL"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf" &&
      output.rendered_secrets["core-exporter"]["PULSO_EXPORTER_KEY_CONTROL_API_SEED"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf:control_api_seed::" &&
      output.rendered_secrets["core-exporter"]["PULSO_EXPORTER_KEY_LAB_BROKER_SEED"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf:lab_broker_seed::" &&
      output.rendered_secrets["platform-exporter"]["PLATFORM_DB_URL"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf" &&
      output.rendered_secrets["platform-exporter"]["PULSO_EXPORTER_KEY_CONTROL_API_SEED"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf:control_api_seed::" &&
      output.rendered_secrets["platform-exporter"]["PULSO_EXPORTER_KEY_LAB_BROKER_SEED"] == "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf:lab_broker_seed::" &&
      !contains(keys(output.rendered_secrets["core-runtime"]), "PULSO_EXPORTER_KEY_LAB_BROKER_SEED") &&
      !contains(keys(output.rendered_secrets["core-runtime"]), "PULSO_EXPORTER_KEY_CONTROL_API_SEED")
    )
    error_message = "Exporters resolve only their own database credential and their own seed secret."
  }
  assert {
    condition = (
      toset(output.execution_secret_arns["core-runtime"]) == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-llm-gateway-token-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf",
      ]) &&
      toset(output.execution_secret_arns["core-exporter"]) == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf",
      ]) &&
      toset(output.execution_secret_arns["platform-exporter"]) == toset([
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf",
        "arn:aws:secretsmanager:us-east-1:123456789012:secret:bridge-test-AbCdEf",
      ])
    )
    error_message = "Each execution role resolves exactly the ARNs of its own variables: no cross-service read, no foreign secret."
  }
  assert {
    condition     = length(output.execution_secret_arns["core-runtime"]) == 6 && length(output.execution_secret_arns["core-exporter"]) == 2 && length(output.execution_secret_arns["platform-exporter"]) == 2
    error_message = "No duplicated or extra ARN in any execution role (the mock gives every own secret one ARN, so sets alone would hide extras)."
  }
  assert {
    condition     = alltrue([for k, c in output.rendered_containers : try(c.readonlyRootFilesystem, false) == true && length(c.mountPoints) >= 2 && contains([for m in c.mountPoints : m.containerPath], "/run/pulso-keys") && contains([for m in c.mountPoints : m.containerPath], "/tmp") && alltrue([for m in c.mountPoints : m.readOnly == false])])
    error_message = "The rendered containers (not module literals) have a read-only root and writable ephemeral /run/pulso-keys and /tmp."
  }
  assert {
    condition     = !contains(keys(output.rendered_containers["core-runtime"]), "user") && !strcontains(jsonencode(output.rendered_containers), "AGENTCORE_ALLOW_DEMO")
    error_message = "The container does not override the image user, and no demo flag is rendered."
  }
}

run "each_database_switch_opens_only_its_own_foreign_group" {
  command = plan

  variables {
    enabled                      = true
    manage_core_database_ingress = true
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.database_from_bridge)) == toset(["core-runtime", "core-exporter"])
    error_message = "manage_core_database_ingress admits the Core services only, never the platform exporter."
  }
}

run "the_platform_database_switch_opens_only_the_platform_group" {
  command = plan

  variables {
    enabled                          = true
    manage_platform_database_ingress = true
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_ingress_rule.database_from_bridge)) == toset(["platform-exporter"])
    error_message = "manage_platform_database_ingress admits the platform exporter only."
  }
}

run "security_group_rules_are_exact_references_ports_and_never_open_cidrs" {
  command = plan

  variables {
    enabled = true
  }

  assert {
    condition     = alltrue([for k, r in aws_vpc_security_group_egress_rule.vpc_https : r.cidr_ipv4 == "10.20.0.0/16" && r.from_port == 443 && r.to_port == 443])
    error_message = "AWS API egress is the VPC CIDR on 443 only."
  }
  assert {
    condition     = alltrue([for k, r in aws_vpc_security_group_egress_rule.to_database : r.from_port == 5432 && r.to_port == 5432 && r.ip_protocol == "tcp" && r.cidr_ipv4 == null]) && alltrue([for k, r in aws_vpc_security_group_ingress_rule.control_api_from_bridge : r.from_port == 8080 && r.to_port == 8080 && r.referenced_security_group_id != null && r.cidr_ipv4 == null]) && alltrue([for k, r in aws_vpc_security_group_egress_rule.to_control_api : r.from_port == 8080 && r.to_port == 8080 && r.cidr_ipv4 == null])
    error_message = "Database and control-api rules are tcp on exactly their port, by security-group reference."
  }
  assert {
    condition     = alltrue([for k, r in aws_vpc_security_group_ingress_rule.runtime_from_engine : r.from_port == 8000 && r.to_port == 8000 && r.cidr_ipv4 == null]) && alltrue([for k, r in aws_vpc_security_group_egress_rule.engine_to_runtime : r.from_port == 8000 && r.to_port == 8000 && r.cidr_ipv4 == null])
    error_message = "F1 is tcp on the runtime port only."
  }
  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.s3_layers)) == toset(["core-runtime", "core-exporter", "platform-exporter"]) && length(aws_vpc_security_group_egress_rule.to_llm_gateway) == 1 && aws_vpc_security_group_egress_rule.to_llm_gateway[0].referenced_security_group_id == "sg-0123456789abcdef5" && aws_vpc_security_group_egress_rule.to_llm_gateway[0].from_port == 8080
    error_message = "ECR layers via the S3 prefix list; the runtime (only) reaches the LLM gateway group."
  }
}

run "no_s3_or_gateway_egress_unless_their_inputs_are_set" {
  command = plan

  variables {
    enabled                          = true
    s3_egress_enabled                = false
    llm_gateway_url                  = ""
    llm_gateway_security_group_id    = ""
    engine_caller_security_group_ids = {}
    core_secret_arns = {
      db_app             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-AbCdEf"
      db_exporter        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf"
      identity_keys      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf"
      staff_keys         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf"
      bridge_service_key = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf"
    }
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.s3_layers) == 0 && length(aws_vpc_security_group_egress_rule.to_llm_gateway) == 0 && length(aws_vpc_security_group_ingress_rule.runtime_from_engine) == 0 && length(aws_vpc_security_group_egress_rule.engine_to_runtime) == 0
    error_message = "Optional egress and engine-side rules appear only when their inputs are set."
  }
}

run "wildcard_secret_arns_are_rejected" {
  command = plan

  variables {
    enabled = true
    core_secret_arns = {
      db_app             = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-*"
      db_exporter        = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-exporter-AbCdEf"
      identity_keys      = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-identity-keys-AbCdEf"
      staff_keys         = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-staff-keys-AbCdEf"
      bridge_service_key = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-bridge-service-key-AbCdEf"
      llm_gateway_token  = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-llm-gateway-token-AbCdEf"
    }
  }

  expect_failures = [var.core_secret_arns]
}

run "unknown_core_secret_keys_are_rejected" {
  command = plan

  variables {
    enabled = true
    core_secret_arns = {
      db_master = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-master-AbCdEf"
    }
  }

  expect_failures = [var.core_secret_arns]
}

run "missing_control_api_inputs_fail_closed" {
  command = plan

  variables {
    enabled                       = true
    control_api_security_group_id = ""
  }

  expect_failures = [aws_security_group.bridge]
}
