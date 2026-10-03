mock_provider "aws" {
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
  aws_region                  = "us-east-1"
  vpc_id                      = "vpc-0123456789abcdef0"
  vpc_cidr                    = "10.20.0.0/16"
  private_subnet_ids          = ["subnet-0123456789abcdef0"]
  cluster_arn                 = "arn:aws:ecs:us-east-1:123456789012:cluster/test-pulso"
  database_security_group_id  = "sg-0123456789abcdef0"
  rds_master_secret_arn_guard = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  secret_name_prefix          = "pulso/test"
  log_retention_days          = 14
  core_runtime_url            = "http://core-runtime.test.pulso.internal:8000"
  tags                        = { Environment = "test" }
}

run "disabled_by_default_plans_zero_resources" {
  command = plan

  assert {
    condition     = length(aws_security_group.engine) == 0 && length(module.workload) == 0 && length(module.workload_sandbox) == 0 && length(module.iam) == 0 && length(module.iam_sandbox) == 0 && length(aws_cloudwatch_log_group.engine) == 0
    error_message = "enabled=false must declare nothing."
  }
  assert {
    condition     = length(aws_service_discovery_service.control_api) == 0 && length(aws_service_discovery_private_dns_namespace.this) == 0 && length(aws_cloudwatch_metric_alarm.running_tasks) == 0 && length(aws_secretsmanager_secret.this) == 0
    error_message = "enabled=false must declare no Cloud Map, secret or alarm."
  }
  assert {
    condition     = output.control_api_dns_name == null && output.service_discovery_namespace_id == ""
    error_message = "enabled=false publishes nothing."
  }
}

run "enabled_requires_digest_images" {
  command = plan

  variables {
    enabled       = true
    image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine:latest"
    sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  expect_failures = [var.image]
}

run "enabled_declares_control_api_worker_migrate_and_sandbox_lab_only" {
  command = plan

  variables {
    enabled       = true
    image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = toset(keys(module.workload)) == toset(["control-api", "worker", "migrate"]) && length(module.workload_sandbox) == 1 && toset(keys(module.iam)) == toset(["control-api", "worker", "migrate"]) && length(module.iam_sandbox) == 1
    error_message = "Four engine workloads, each with its own roles. human-issuer is local-only and console hosting is dependency_blocked (edge): neither is declared."
  }
  assert {
    condition     = output.control_api_dns_name == "control-api.test.pulso.internal"
    error_message = "control-api (which serves the lab-broker audience too) is reached by Cloud Map private DNS; no ALB, no WAF."
  }
  assert {
    condition     = length(aws_service_discovery_service.control_api) == 1 && length(aws_service_discovery_private_dns_namespace.this) == 1
    error_message = "One Cloud Map service for control-api."
  }
}

run "no_core_authority_or_provider_secret_reaches_the_engine" {
  command = plan

  variables {
    enabled       = true
    image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition = alltrue([
      for k, w in local.workloads : alltrue([
        for n in concat(keys(w.environment), keys(w.secrets)) :
        !startswith(n, "CORE_") && !startswith(n, "AGENTCORE_") && !startswith(n, "LLM_") && !can(regex("PROVIDER|JEV", n))
      ])
    ])
    error_message = "Plan 16.17: Rust receives neither Core DSNs, provider keys nor Jev keys."
  }
  assert {
    condition     = length(local.workloads["sandbox-lab"].secrets) == 0 && length(local.workloads["sandbox-lab"].secret_arns) == 0
    error_message = "sandbox-lab holds no secret."
  }
}

run "secret_entries_are_per_workload_names_only" {
  command = plan

  variables {
    enabled       = true
    image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = toset(keys(aws_secretsmanager_secret.this)) == toset(["db-control-api", "db-worker", "db-migrate", "service-key-control-api", "service-key-worker", "verifier-keys"])
    error_message = "One entry per workload need; the public keys of the integration keypairs live in one verifier entry read only by control-api."
  }
  assert {
    condition     = alltrue([for s in values(aws_secretsmanager_secret.this) : startswith(s.name, "pulso/test/engine/")])
    error_message = "Entries live under <prefix>/engine/, separate from the Core and legacy runtime entries."
  }
}

run "network_rules_follow_the_flow_matrix" {
  command = plan

  variables {
    enabled                          = true
    image                            = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image                    = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    core_runtime_security_group_ids  = ["sg-0aaaaaaaaaaaaaaaa"]
    core_callback_security_group_ids = ["sg-0bbbbbbbbbbbbbbbb"]
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.to_database)) == toset(["control-api", "worker", "migrate"])
    error_message = "F4: only control-api, worker and migrate reach the engine database; sandbox-lab never does."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.control_api_from_core) == 1 && aws_vpc_security_group_ingress_rule.control_api_from_core[0].from_port == 8080
    error_message = "F2/F3: Core callbacks and exporter reach control-api on 8080 by security group only."
  }
  assert {
    condition     = toset([for k in keys(aws_vpc_security_group_egress_rule.to_core_runtime) : split("|", k)[0]]) == toset(["control-api", "worker"])
    error_message = "F1: control-api and worker call core-runtime."
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.sandbox_https_vpc) == 1
    error_message = "F9: sandbox-lab reaches VPC endpoints only."
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.vpc_https) == 3
    error_message = "control-api, worker and migrate reach AWS APIs through VPC endpoints inside the VPC CIDR (no 0.0.0.0/0 anywhere in this module)."
  }
}

run "worker_may_launch_only_the_sandbox_task" {
  command = plan

  variables {
    enabled       = true
    image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = contains(flatten([for s in local.worker_task_statements : s.Action]), "ecs:RunTask") && !contains(flatten([for s in local.worker_task_statements : s.Action]), "iam:PassRole")
    error_message = "Worker task role: ecs:RunTask (iam:PassRole comes only through the constrained pass_role_arns path)."
  }
  assert {
    condition     = alltrue([for s in local.worker_task_statements : can(s.Condition.ArnEquals["ecs:cluster"])])
    error_message = "Every ECS statement is conditioned on the shared cluster."
  }
}

run "alarms_only_when_tasks_are_expected" {
  command = plan

  variables {
    enabled                   = true
    control_api_desired_count = 1
    worker_desired_count      = 1
    alarm_actions             = ["arn:aws:sns:us-east-1:123456789012:test"]
    image                     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image             = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = toset(keys(aws_cloudwatch_metric_alarm.running_tasks)) == toset(["control-api", "worker"])
    error_message = "Running-task alarms for the two services."
  }
}

run "no_alarms_at_zero_desired_count" {
  command = plan

  variables {
    enabled       = true
    image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.running_tasks) == 0
    error_message = "A zero-task posture must not page anyone."
  }
}

run "s3_prefix_list_egress_lets_every_workload_pull_ecr_layers" {
  command = plan

  variables {
    enabled           = true
    s3_egress_enabled = true
    s3_prefix_list_id = "pl-0123456789abcdef0"
    image             = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = toset(keys(aws_vpc_security_group_egress_rule.s3_layers)) == toset(["control-api", "worker", "migrate", "sandbox-lab"])
    error_message = "ECR layers come from S3 (gateway endpoint): a VPC-CIDR rule does not cover them, so every task needs the prefix-list rule."
  }
  assert {
    condition     = alltrue([for r in values(aws_vpc_security_group_egress_rule.s3_layers) : r.prefix_list_id == "pl-0123456789abcdef0" && r.from_port == 443 && r.to_port == 443])
    error_message = "S3 egress is the endpoint prefix list on 443 only."
  }
}

run "no_s3_rule_unless_the_gateway_endpoint_exists" {
  command = plan

  variables {
    enabled       = true
    image         = "123456789012.dkr.ecr.us-east-1.amazonaws.com/engine@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    sandbox_image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/sandbox@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
  }

  assert {
    condition     = length(aws_vpc_security_group_egress_rule.s3_layers) == 0
    error_message = "Default plans no S3 egress."
  }
}
