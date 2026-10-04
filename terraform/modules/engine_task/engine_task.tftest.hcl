mock_provider "aws" {}

variables {
  aws_region         = "test-region-1"
  tags               = { Environment = "test", ManagedBy = "terraform", Service = "pulso" }
  cluster_arn        = "arn:aws:ecs:test-region-1:000000000000:cluster/test"
  subnet_ids         = ["subnet-aaaa1111"]
  security_group_ids = ["sg-aaaa1111"]
  bucket_name        = "test-pulso-data"
}

run "disabled_by_default_plans_nothing" {
  command = plan

  assert {
    condition     = length(aws_ecs_task_definition.this) == 0 && length(aws_ecs_service.this) == 0 && length(aws_cloudwatch_log_group.this) == 0
    error_message = "enabled=false must plan zero resources (not wired by default)."
  }
}

run "enabled_declares_pulso_and_core_runtime_sidecar_pinned_by_digest" {
  command = plan

  variables {
    enabled            = true
    pulso_image        = "repo/pulso@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    core_runtime_image = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  assert {
    condition     = toset([for c in jsondecode(aws_ecs_task_definition.this[0].container_definitions) : c.name]) == toset(["pulso", "core-runtime"])
    error_message = "Task layout is pulso plus the core-runtime sidecar (design section 9)."
  }

  assert {
    condition     = [for c in jsondecode(aws_ecs_task_definition.this[0].container_definitions) : c.image if c.name == "core-runtime"][0] == "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    error_message = "core-runtime must use the pinned digest variable."
  }

  assert {
    condition     = [for c in jsondecode(aws_ecs_task_definition.this[0].container_definitions) : c.dependsOn[0].condition if c.name == "pulso"][0] == "HEALTHY"
    error_message = "pulso starts only after core-runtime is HEALTHY."
  }

  assert {
    condition     = alltrue([for c in jsondecode(aws_ecs_task_definition.this[0].container_definitions) : c.readonlyRootFilesystem && c.user != "root" && c.user != "0"])
    error_message = "Containers run non-root with a read-only root filesystem."
  }

  assert {
    condition     = [for c in jsondecode(aws_ecs_task_definition.this[0].container_definitions) : c.stopTimeout if c.name == "pulso"][0] >= 60
    error_message = "pulso needs stopTimeout >= 60 s to drain on SIGTERM."
  }

  assert {
    condition     = alltrue([for c in jsondecode(aws_ecs_task_definition.this[0].container_definitions) : c.logConfiguration.logDriver == "awslogs"])
    error_message = "All containers log to CloudWatch."
  }
}

run "images_without_digest_are_rejected" {
  command = plan

  variables {
    enabled            = true
    pulso_image        = "repo/pulso:latest"
    core_runtime_image = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  expect_failures = [var.pulso_image]
}

run "desired_count_defaults_to_zero" {
  command = plan

  variables {
    enabled            = true
    pulso_image        = "repo/pulso@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    core_runtime_image = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  assert {
    condition     = aws_ecs_service.this[0].desired_count == 0
    error_message = "Default desired_count is 0 (nothing runs until a human raises it)."
  }
}

run "kill_switch_wins_over_desired_count" {
  command = plan

  variables {
    enabled            = true
    desired_count      = 1
    kill_switch        = true
    pulso_image        = "repo/pulso@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    core_runtime_image = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  assert {
    condition     = aws_ecs_service.this[0].desired_count == 0
    error_message = "kill_switch=true must force desired_count=0."
  }
}

run "no_public_ip_and_launch_type_is_selectable" {
  command = plan

  variables {
    enabled            = true
    launch_type        = "EC2"
    pulso_image        = "repo/pulso@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    core_runtime_image = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  assert {
    condition     = aws_ecs_service.this[0].launch_type == "EC2" && contains(aws_ecs_task_definition.this[0].requires_compatibilities, "EC2")
    error_message = "launch_type EC2 must flow to the service and the task definition."
  }

  assert {
    condition     = aws_ecs_service.this[0].network_configuration[0].assign_public_ip == false
    error_message = "Never a public IP."
  }
}

run "launch_type_is_validated" {
  command = plan

  variables {
    launch_type = "SPOT"
  }

  expect_failures = [var.launch_type]
}

run "secrets_come_by_arn_and_bucket_is_plain_configuration" {
  command = plan

  variables {
    enabled            = true
    pulso_image        = "repo/pulso@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    core_runtime_image = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
    secret_arns        = { PULSO_PG_APP_DSN = "arn:aws:secretsmanager:test-region-1:000000000000:secret:test/db_app-AbCdEf" }
    environment        = { PULSO_DATA_MODE = "product" }
  }

  assert {
    condition     = [for c in jsondecode(aws_ecs_task_definition.this[0].container_definitions) : c.secrets[0].valueFrom if c.name == "pulso"][0] == "arn:aws:secretsmanager:test-region-1:000000000000:secret:test/db_app-AbCdEf"
    error_message = "Secrets are injected by ARN."
  }

  assert {
    condition     = anytrue([for e in [for c in jsondecode(aws_ecs_task_definition.this[0].container_definitions) : c.environment if c.name == "pulso"][0] : e.name == "PULSO_S3_BUCKET" && e.value == "test-pulso-data"])
    error_message = "Bucket name is passed as non-secret configuration."
  }
}

run "secret_values_instead_of_arns_are_rejected" {
  command = plan

  variables {
    secret_arns = { PULSO_PG_APP_DSN = "postgres://user:pw@host/db" }
  }

  expect_failures = [var.secret_arns]
}

run "task_role_s3_access_is_limited_to_the_prefixes" {
  command = plan

  variables {
    enabled            = true
    pulso_image        = "repo/pulso@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    core_runtime_image = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  assert {
    condition     = strcontains(aws_iam_role_policy.task_s3[0].policy, "arn:aws:s3:::test-pulso-data/artifacts/*") && strcontains(aws_iam_role_policy.task_s3[0].policy, "arn:aws:s3:::test-pulso-data/console/*") && !strcontains(aws_iam_role_policy.task_s3[0].policy, "\"Resource\":\"*\"")
    error_message = "S3 access is limited to the bucket prefixes."
  }
}

run "alarms_cover_engine_health_logs_and_database" {
  command = plan

  variables {
    enabled                = true
    db_instance_identifier = "test-db"
    alarm_actions          = ["arn:aws:sns:test-region-1:000000000000:alerts"]
    pulso_image            = "repo/pulso@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    core_runtime_image     = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.engine_running[0].alarm_name != "" && aws_cloudwatch_metric_alarm.engine_errors[0].alarm_name != ""
    error_message = "Engine health and error alarms must exist."
  }

  assert {
    condition     = aws_cloudwatch_metric_alarm.db_cpu[0].namespace == "AWS/RDS" && aws_cloudwatch_metric_alarm.db_storage[0].namespace == "AWS/RDS" && aws_cloudwatch_metric_alarm.db_connections[0].namespace == "AWS/RDS"
    error_message = "Database alarms must exist when the DB identifier is given."
  }

  assert {
    condition     = aws_cloudwatch_log_group.this[0].retention_in_days == 30
    error_message = "Log retention is explicit (default 30 days)."
  }
}

run "no_db_identifier_means_no_db_alarms" {
  command = plan

  variables {
    enabled            = true
    pulso_image        = "repo/pulso@sha256:1111111111111111111111111111111111111111111111111111111111111111"
    core_runtime_image = "repo/core@sha256:2222222222222222222222222222222222222222222222222222222222222222"
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.db_cpu) == 0
    error_message = "DB alarms need the identifier."
  }
}
