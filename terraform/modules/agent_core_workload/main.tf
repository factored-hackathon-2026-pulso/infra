# Agent Core as an ECS/Fargate workload (ADR 0003, ADR 0005). One image, four roles:
#   serve   - the HTTP API behind the internal ALB (autoscaled)
#   relay   - publishes the outbox to SNS (singleton by advisory lock, always on)
#   sweep   - closes inactive runs; launched every few minutes by EventBridge Scheduler
#   migrate - one-off schema task, run by hand or by a reviewed pipeline before a service update
#
# Secret *entries* are created here (names and encryption only). Their values are set out of band and never
# pass through Terraform state.

locals {
  env  = var.tags["Environment"]
  name = "${local.env}-agent-core"

  base_secret_names = [
    "AGENTCORE_REGISTRY_DSN",
    "AGENTCORE_EVAL_DSN",
    "AGENTCORE_KEYS_FINGERPRINT",
    "AGENTCORE_KEYS_TOKEN_MAP",
    "AGENTCORE_JEV_API_KEY",
    "LLM_ENDPOINTS",
  ]
  secret_names = toset(concat(local.base_secret_names, var.extra_secret_names))

  secret_arns = { for n, s in aws_secretsmanager_secret.this : n => s.arn }

  # Which secrets each role needs (least privilege at the task level).
  secrets_by_role = {
    serve   = sort(tolist(local.secret_names))
    migrate = ["AGENTCORE_EVAL_DSN", "AGENTCORE_REGISTRY_DSN"]
    sweep   = ["AGENTCORE_REGISTRY_DSN"]
    relay   = ["AGENTCORE_REGISTRY_DSN"]
  }

  shared_environment = merge(
    {
      AWS_REGION               = var.aws_region
      AGENTCORE_DB_POOL_MAX    = tostring(var.db_pool_max)
      AGENTCORE_BLOB_BUCKET    = var.blob_bucket_name
      AGENTCORE_BLOB_PREFIX    = "blobs"
      OTEL_SERVICE_NAME        = "agent-core"
      OTEL_RESOURCE_ATTRIBUTES = "deployment.environment=${local.env}"
    },
    var.blob_kms_key_arn == "" ? {} : { AGENTCORE_BLOB_KMS_KEY_ARN = var.blob_kms_key_arn },
    var.otel_environment,
  )

  role_environment = {
    serve = merge(
      local.shared_environment,
      var.serve_agents == "" ? {} : { AGENTCORE_SERVE_AGENTS = var.serve_agents },
      var.allow_demo ? { AGENTCORE_ALLOW_DEMO = "1" } : {},
    )
    migrate = local.shared_environment
    sweep   = local.shared_environment
    relay   = merge(local.shared_environment, { AGENTCORE_EVENTS_TOPIC_ARN = var.events_topic_arn })
  }

  role_command = {
    serve   = var.serve_command
    migrate = ["migrate"]
    sweep   = ["sweep", "--once"]
    relay   = ["relay"]
  }

  role_size = {
    serve   = { cpu = tostring(var.serve_cpu), memory = tostring(var.serve_memory) }
    migrate = { cpu = "256", memory = "512" }
    sweep   = { cpu = "256", memory = "512" }
    relay   = { cpu = "256", memory = "512" }
  }

  role_extras = {
    serve = {
      portMappings = [{ containerPort = var.container_port, protocol = "tcp" }]
      healthCheck  = local.health_check
    }
    migrate = {}
    sweep   = {}
    relay   = {}
  }

  # Same probe as the image's HEALTHCHECK (ECS ignores Docker HEALTHCHECK).
  health_check = {
    command     = ["CMD", "python", "-c", "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:${var.container_port}/healthz', timeout=2).status == 200 else 1)"]
    interval    = 15
    timeout     = 3
    retries     = 3
    startPeriod = 20
  }
}

# --- Logs and secret entries ---------------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "this" {
  name              = "/pulso/${local.env}/agent-core"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_secretsmanager_secret" "this" {
  for_each                = local.secret_names
  name                    = "${var.secret_name_prefix}/${each.value}"
  kms_key_id              = var.secrets_kms_key_arn == "" ? null : var.secrets_kms_key_arn
  recovery_window_in_days = 7
  tags                    = var.tags
}

# --- IAM -----------------------------------------------------------------------------------------------------

locals {
  ecs_assume_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { Service = ["ecs-tasks.amazonaws.com"] }
    }]
  })
  scheduler_assume_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = ["sts:AssumeRole"]
      Principal = { Service = ["scheduler.amazonaws.com"] }
    }]
  })
}

resource "aws_iam_role" "execution" {
  name_prefix          = "${local.name}-exec-"
  assume_role_policy   = local.ecs_assume_policy
  permissions_boundary = var.permissions_boundary == "" ? null : var.permissions_boundary
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS resolves task-definition secrets before the container starts, so this belongs to the execution role.
resource "aws_iam_role_policy" "execution_secrets" {
  name = "resolve-agent-core-secrets"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Sid      = "ReadAgentCoreSecrets"
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = values(local.secret_arns)
      }], var.secrets_kms_key_arn == "" ? [] : [{
      Sid      = "DecryptAgentCoreSecrets"
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = [var.secrets_kms_key_arn]
      Condition = {
        StringEquals = { "kms:ViaService" = "secretsmanager.${var.aws_region}.amazonaws.com" }
      }
    }])
  })
}

resource "aws_iam_role" "task" {
  name_prefix          = "${local.name}-task-"
  assume_role_policy   = local.ecs_assume_policy
  permissions_boundary = var.permissions_boundary == "" ? null : var.permissions_boundary
  tags                 = var.tags
}

# What the code itself may do at runtime: read and add registry blobs (never delete), publish outbound events.
# Secrets are injected by ECS, so the task role cannot read Secrets Manager.
resource "aws_iam_role_policy" "task" {
  name = "agent-core-runtime"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "ListBlobBucket"
          Effect   = "Allow"
          Action   = ["s3:ListBucket"] # without it a missing key answers 403 instead of 404
          Resource = [var.blob_bucket_arn]
        },
        {
          Sid      = "ReadAndAddBlobs"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject"]
          Resource = ["${var.blob_bucket_arn}/*"]
        },
        {
          Sid      = "PublishOutboundEvents"
          Effect   = "Allow"
          Action   = ["sns:Publish"]
          Resource = [var.events_topic_arn]
        },
        {
          Sid      = "UseSnsManagedKey"
          Effect   = "Allow"
          Action   = ["kms:GenerateDataKey*", "kms:Decrypt"]
          Resource = ["*"]
          Condition = {
            StringEquals = { "kms:ViaService" = "sns.${var.aws_region}.amazonaws.com" }
          }
        },
      ],
      var.blob_kms_key_arn == "" ? [] : [{
        Sid      = "UseBlobKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = [var.blob_kms_key_arn]
        Condition = {
          StringEquals = { "kms:ViaService" = "s3.${var.aws_region}.amazonaws.com" }
        }
      }],
    )
  })
}

# --- Task definitions ----------------------------------------------------------------------------------------

resource "aws_ecs_task_definition" "role" {
  for_each = local.role_command

  family                   = "${local.name}-${each.key}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = local.role_size[each.key].cpu
  memory                   = local.role_size[each.key].memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.cpu_architecture
  }

  container_definitions = jsonencode([merge(
    {
      name            = "agent-core"
      image           = var.image
      essential       = true
      command         = local.role_command[each.key]
      stopTimeout     = 30 # SIGTERM -> finish the current pass/turn
      linuxParameters = { initProcessEnabled = true }
      environment     = [for k, v in local.role_environment[each.key] : { name = k, value = v }]
      secrets         = [for n in local.secrets_by_role[each.key] : { name = n, valueFrom = local.secret_arns[n] }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.this.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = each.key
        }
      }
    },
    local.role_extras[each.key],
  )])

  tags = var.tags

  lifecycle {
    precondition {
      condition     = !var.allow_demo || local.env == "prod"
      error_message = "AGENTCORE_ALLOW_DEMO is acceptable only in the hackathon prod demo (ADR 0003 item 5)."
    }
  }
}

# --- Services ------------------------------------------------------------------------------------------------

resource "aws_ecs_service" "serve" {
  name                               = "agent-core"
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.role["serve"].arn
  desired_count                      = var.serve_desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60
  propagate_tags                     = "SERVICE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = var.target_group_arn
    container_name   = "agent-core"
    container_port   = var.container_port
  }

  tags = var.tags

  lifecycle {
    ignore_changes = [desired_count] # owned by Application Auto Scaling
  }
}

resource "aws_ecs_service" "relay" {
  name                               = "agent-core-relay"
  cluster                            = var.cluster_arn
  task_definition                    = aws_ecs_task_definition.role["relay"].arn
  desired_count                      = var.relay_desired_count
  launch_type                        = "FARGATE"
  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  propagate_tags                     = "SERVICE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  tags = var.tags
}

# --- Autoscaling of the API ----------------------------------------------------------------------------------

resource "aws_appautoscaling_target" "serve" {
  max_capacity       = var.serve_max_count
  min_capacity       = var.serve_min_count
  resource_id        = "service/${var.cluster_name}/${aws_ecs_service.serve.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "${local.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.serve.resource_id
  scalable_dimension = aws_appautoscaling_target.serve.scalable_dimension
  service_namespace  = aws_appautoscaling_target.serve.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target_percent
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

resource "aws_appautoscaling_policy" "requests" {
  name               = "${local.name}-requests"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.serve.resource_id
  scalable_dimension = aws_appautoscaling_target.serve.scalable_dimension
  service_namespace  = aws_appautoscaling_target.serve.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = var.requests_per_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${var.load_balancer_arn_suffix}/${var.target_group_arn_suffix}"
    }
  }
}

# --- Scheduled sweep -----------------------------------------------------------------------------------------

resource "aws_iam_role" "scheduler" {
  name_prefix          = "${local.name}-sched-"
  assume_role_policy   = local.scheduler_assume_policy
  permissions_boundary = var.permissions_boundary == "" ? null : var.permissions_boundary
  tags                 = var.tags
}

resource "aws_iam_role_policy" "scheduler" {
  name = "run-sweep-task"
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RunSweep"
        Effect   = "Allow"
        Action   = ["ecs:RunTask"]
        Resource = ["${aws_ecs_task_definition.role["sweep"].arn_without_revision}:*"]
        Condition = {
          ArnEquals = { "ecs:cluster" = var.cluster_arn }
        }
      },
      {
        Sid      = "PassTaskRoles"
        Effect   = "Allow"
        Action   = ["iam:PassRole"]
        Resource = [aws_iam_role.execution.arn, aws_iam_role.task.arn]
        Condition = {
          StringEquals = { "iam:PassedToService" = "ecs-tasks.amazonaws.com" }
        }
      },
    ]
  })
}

resource "aws_scheduler_schedule" "sweep" {
  name                = "${local.name}-sweep"
  description         = "agentcore sweep --once: closes runs past their inactivity deadline."
  schedule_expression = var.sweep_schedule
  state               = var.sweep_enabled ? "ENABLED" : "DISABLED"
  flexible_time_window { mode = "OFF" }

  target {
    arn      = var.cluster_arn
    role_arn = aws_iam_role.scheduler.arn

    ecs_parameters {
      task_definition_arn = aws_ecs_task_definition.role["sweep"].arn_without_revision
      launch_type         = "FARGATE"
      platform_version    = "LATEST"
      propagate_tags      = "TASK_DEFINITION"

      network_configuration {
        subnets          = var.private_subnet_ids
        security_groups  = var.security_group_ids
        assign_public_ip = false
      }
    }

    retry_policy {
      maximum_retry_attempts       = 2
      maximum_event_age_in_seconds = 300
    }
  }
}
