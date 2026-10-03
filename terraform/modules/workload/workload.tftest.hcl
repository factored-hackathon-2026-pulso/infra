mock_provider "aws" {}

variables {
  name                        = "pulso-core-runtime"
  image                       = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso-core-runtime@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
  cluster_arn                 = "arn:aws:ecs:us-east-1:123456789012:cluster/test-pulso"
  subnet_ids                  = ["subnet-0123456789abcdef0"]
  security_group_ids          = ["sg-0123456789abcdef0"]
  task_role_arn               = "arn:aws:iam::123456789012:role/core-task"
  execution_role_arn          = "arn:aws:iam::123456789012:role/core-exec"
  aws_region                  = "us-east-1"
  log_group_name              = "/pulso/test/pulso-core-runtime"
  port                        = 8000
  cpu                         = 512
  memory                      = 1024
  desired_count               = 0
  environment                 = { AGENTCORE_LOG_LEVEL = "info" }
  secrets                     = { AGENTCORE_JEV_API_KEY = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-jev-test" }
  rds_master_secret_arn_guard = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test"
  tags                        = { Environment = "test" }
}

run "digest_pinned_image_plans_a_private_fargate_service" {
  command = plan

  assert {
    condition     = aws_ecs_service.this[0].network_configuration[0].assign_public_ip == false
    error_message = "T-03: the service must never receive a public IP."
  }
  assert {
    condition     = aws_ecs_service.this[0].deployment_circuit_breaker[0].enable && aws_ecs_service.this[0].deployment_circuit_breaker[0].rollback
    error_message = "The deployment circuit breaker must be enabled with rollback."
  }
  assert {
    condition     = aws_ecs_service.this[0].launch_type == "FARGATE" && aws_ecs_task_definition.this.requires_compatibilities == toset(["FARGATE"])
    error_message = "The workload is Fargate-only."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].image == var.image
    error_message = "The container must run the exact digest image."
  }
  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].stopTimeout == 30
    error_message = "stopTimeout must default to 30 seconds."
  }
}

run "log_group_is_consumed_never_created" {
  command = plan

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].logConfiguration.options["awslogs-group"] == var.log_group_name
    error_message = "T-12: the log group name comes from the observability owner."
  }
}

run "health_check_and_service_registry_are_optional_inputs" {
  command = plan

  variables {
    health_check_command = ["CMD-SHELL", "python -c 'import urllib.request as u; u.urlopen(\"http://127.0.0.1:8000/healthz\")'"]
    service_registry_arn = "arn:aws:servicediscovery:us-east-1:123456789012:service/srv-0123456789abcdef"
  }

  assert {
    condition     = jsondecode(aws_ecs_task_definition.this.container_definitions)[0].healthCheck.command[0] == "CMD-SHELL"
    error_message = "healthCheck must render when a command is supplied."
  }
  assert {
    condition     = aws_ecs_service.this[0].service_registries[0].registry_arn == var.service_registry_arn
    error_message = "Cloud Map registration must render when supplied."
  }
}

run "one_off_task_has_no_service" {
  command = plan

  variables {
    create_service = false
    port           = null
  }

  assert {
    condition     = length(aws_ecs_service.this) == 0
    error_message = "A one-off task definition (migrate/sweep) must not create a service."
  }
}

run "t01_mutable_tag_is_rejected" {
  command = plan

  variables {
    image = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso-core-runtime:latest"
  }

  expect_failures = [var.image]
}

run "t01_short_digest_is_rejected" {
  command = plan

  variables {
    image = "repo/x@sha256:abc"
  }

  expect_failures = [var.image]
}

run "t02_demo_flag_in_environment_is_rejected" {
  command = plan

  variables {
    environment = { AGENTCORE_ALLOW_DEMO = "1" }
  }

  expect_failures = [var.environment]
}

run "t02_demo_flag_in_secrets_is_rejected" {
  command = plan

  variables {
    secrets = { AGENTCORE_ALLOW_DEMO = "arn:aws:secretsmanager:us-east-1:123456789012:secret:x" }
  }

  expect_failures = [var.secrets]
}

run "t02_demo_flag_smuggled_through_command_is_rejected" {
  command = plan

  variables {
    command = ["sh", "-c", "AGENTCORE_ALLOW_DEMO=1 agentcore serve"]
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "t03_invalid_cpu_memory_pair_is_rejected" {
  command = plan

  variables {
    cpu    = 256
    memory = 4096
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "t03_valid_large_pair_is_accepted" {
  command = plan

  variables {
    cpu    = 4096
    memory = 16384
  }

  assert {
    condition     = aws_ecs_task_definition.this.cpu == "4096"
    error_message = "A valid Fargate pair must plan."
  }
}

run "master_secret_cannot_be_injected_into_a_workload" {
  command = plan

  variables {
    secrets = { DB = "arn:aws:secretsmanager:us-east-1:123456789012:secret:rds-master-test:registry_dsn::" }
  }

  expect_failures = [aws_ecs_task_definition.this]
}

run "per_key_secret_references_are_accepted" {
  command = plan

  variables {
    secrets = {
      AGENTCORE_REGISTRY_DSN = "arn:aws:secretsmanager:us-east-1:123456789012:secret:core-db-app-test:registry_dsn::"
    }
  }

  assert {
    condition     = length(jsondecode(aws_ecs_task_definition.this.container_definitions)[0].secrets) == 1
    error_message = "valueFrom with a JSON key suffix must be accepted."
  }
}

run "stop_timeout_above_fargate_limit_is_rejected" {
  command = plan

  variables {
    stop_timeout = 300
  }

  expect_failures = [var.stop_timeout]
}
