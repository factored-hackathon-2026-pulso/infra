# Engine task (docs/plan-real/r1-real-system-design.md section 9): ONE ECS task with the `pulso` container
# (engine + control-api + monitor loop) and the `core-runtime` sidecar, pinned by image digest. The llm-gateway
# sidecar and the optional console container are not declared here (the gateway is not ours; the console is served
# from the bucket console/ prefix or by pulso).
#
# Consumed, never created here: ECS cluster, subnets, security groups, RDS Postgres, the shared bucket, secrets.
# Database: one instance, one database. Roles and schemas (raw, augmented, product, pulso) are created by the engine
# at start from db/sql (idempotent) and migrations/ under an advisory lock; Terraform creates no schema or login.
# No load balancer, no public IP, no public endpoint.
locals {
  name          = "${var.tags["Environment"]}-pulso-engine"
  desired_count = var.kill_switch ? 0 : var.desired_count
  cluster_name  = element(split("/", var.cluster_arn), length(split("/", var.cluster_arn)) - 1)
  secret_arns   = values(var.secret_arns)
  user          = "10001:10001"

  base_environment = merge(
    {
      PULSO_S3_BUCKET       = var.bucket_name
      PULSO_S3_PREFIXES     = join(",", var.bucket_prefixes)
      PULSO_PG_ENDPOINT     = var.database_endpoint
      PULSO_PG_DATABASE     = var.database_name
      PULSO_CORE_BRIDGE_URL = "http://localhost:${var.core_runtime_port}"
    },
    var.environment,
  )

  log_config = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"         = local.name
      "awslogs-region"        = var.aws_region
      "awslogs-stream-prefix" = "engine"
    }
  }

  health = {
    pulso = ["CMD-SHELL", "curl -fsS http://localhost:${var.pulso_port}/healthz || exit 1"]
    core  = ["CMD-SHELL", "curl -fsS http://localhost:${var.core_runtime_port}/healthz || exit 1"]
  }

  container_definitions = [
    {
      name                   = "core-runtime"
      image                  = var.core_runtime_image
      essential              = true
      user                   = local.user
      readonlyRootFilesystem = true
      portMappings           = [{ containerPort = var.core_runtime_port, protocol = "tcp" }]
      mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
      healthCheck            = { command = local.health.core, interval = 15, timeout = 5, retries = 5, startPeriod = 30 }
      logConfiguration       = local.log_config
    },
    {
      name                   = "pulso"
      image                  = var.pulso_image
      essential              = true
      user                   = local.user
      readonlyRootFilesystem = true
      stopTimeout            = 60
      portMappings           = [{ containerPort = var.pulso_port, protocol = "tcp" }]
      mountPoints            = [{ sourceVolume = "tmp", containerPath = "/tmp", readOnly = false }]
      environment            = [for k, v in local.base_environment : { name = k, value = v }]
      secrets                = [for k, v in var.secret_arns : { name = k, valueFrom = v }]
      dependsOn              = [{ containerName = "core-runtime", condition = "HEALTHY" }]
      healthCheck            = { command = local.health.pulso, interval = 15, timeout = 5, retries = 5, startPeriod = 60 }
      logConfiguration       = local.log_config
    },
  ]
}

resource "aws_cloudwatch_log_group" "this" {
  count             = var.enabled ? 1 : 0
  name              = local.name
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

# --- IAM: engine-specific execution and task roles, scoped to the given secret ARNs and bucket prefixes ---

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  count                = var.enabled ? 1 : 0
  name                 = "${local.name}-exec"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = var.permissions_boundary == "" ? null : var.permissions_boundary
  tags                 = var.tags
}

resource "aws_iam_role_policy_attachment" "execution" {
  count      = var.enabled ? 1 : 0
  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "execution_secrets" {
  count = var.enabled && length(local.secret_arns) > 0 ? 1 : 0
  name  = "read-listed-secrets"
  role  = aws_iam_role.execution[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "ssm:GetParameters"]
        Resource = local.secret_arns
      }],
      var.kms_key_arn == "" ? [] : [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.kms_key_arn]
      }],
    )
  })
}

resource "aws_iam_role" "task" {
  count                = var.enabled ? 1 : 0
  name                 = "${local.name}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = var.permissions_boundary == "" ? null : var.permissions_boundary
  tags                 = var.tags
}

resource "aws_iam_role_policy" "task_s3" {
  count = var.enabled ? 1 : 0
  name  = "bucket-prefixes"
  role  = aws_iam_role.task[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = ["arn:aws:s3:::${var.bucket_name}"]
        Condition = { StringLike = { "s3:prefix" = [for p in var.bucket_prefixes : "${p}/*"] } }
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = [for p in var.bucket_prefixes : "arn:aws:s3:::${var.bucket_name}/${p}/*"]
      },
    ]
  })
}

# --- task and service ---

resource "aws_ecs_task_definition" "this" {
  count                    = var.enabled ? 1 : 0
  family                   = local.name
  requires_compatibilities = [var.launch_type]
  network_mode             = "awsvpc"
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = aws_iam_role.execution[0].arn
  task_role_arn            = aws_iam_role.task[0].arn
  container_definitions    = jsonencode(local.container_definitions)

  volume {
    name = "tmp"
  }

  tags = var.tags
}

resource "aws_ecs_service" "this" {
  count                  = var.enabled ? 1 : 0
  name                   = local.name
  cluster                = var.cluster_arn
  task_definition        = aws_ecs_task_definition.this[0].arn
  desired_count          = local.desired_count
  launch_type            = var.launch_type
  enable_execute_command = false

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  tags = var.tags
}

# --- alarms ---

resource "aws_cloudwatch_metric_alarm" "engine_running" {
  count               = var.enabled ? 1 : 0
  alarm_name          = "${local.name}-not-running"
  alarm_description   = "No CPU datapoints from the engine service: the task is down or not placed. Silent while the kill switch or desired_count is 0."
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = local.cluster_name, ServiceName = local.name }
  statistic           = "SampleCount"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = local.desired_count > 0 ? "breaching" : "notBreaching"
  alarm_actions       = var.alarm_actions
  ok_actions          = var.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_log_metric_filter" "engine_errors" {
  count          = var.enabled ? 1 : 0
  name           = "${local.name}-errors"
  log_group_name = aws_cloudwatch_log_group.this[0].name
  pattern        = "?ERROR ?FATAL ?panic"

  metric_transformation {
    name      = "EngineErrors"
    namespace = "Pulso/Engine"
    value     = "1"
  }
}

resource "aws_cloudwatch_metric_alarm" "engine_errors" {
  count               = var.enabled ? 1 : 0
  alarm_name          = "${local.name}-errors"
  alarm_description   = "ERROR, FATAL or panic lines in the engine log (includes failed /readyz and migration failures)."
  namespace           = "Pulso/Engine"
  metric_name         = "EngineErrors"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = var.tags
}

locals {
  db_alarms_enabled = var.enabled && var.db_instance_identifier != ""
}

resource "aws_cloudwatch_metric_alarm" "db_cpu" {
  count               = local.db_alarms_enabled ? 1 : 0
  alarm_name          = "${local.name}-db-cpu"
  namespace           = "AWS/RDS"
  metric_name         = "CPUUtilization"
  dimensions          = { DBInstanceIdentifier = var.db_instance_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 80
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = var.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "db_storage" {
  count               = local.db_alarms_enabled ? 1 : 0
  alarm_name          = "${local.name}-db-free-storage"
  namespace           = "AWS/RDS"
  metric_name         = "FreeStorageSpace"
  dimensions          = { DBInstanceIdentifier = var.db_instance_identifier }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 2147483648
  comparison_operator = "LessThanThreshold"
  alarm_actions       = var.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "db_connections" {
  count               = local.db_alarms_enabled ? 1 : 0
  alarm_name          = "${local.name}-db-connections"
  namespace           = "AWS/RDS"
  metric_name         = "DatabaseConnections"
  dimensions          = { DBInstanceIdentifier = var.db_instance_identifier }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 60
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = var.alarm_actions
  tags                = var.tags
}
