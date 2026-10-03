locals {
  # Valid Fargate cpu -> memory (MiB) combinations.
  fargate_memory = {
    256   = [512, 1024, 2048]
    512   = [1024, 2048, 3072, 4096]
    1024  = [2048, 3072, 4096, 5120, 6144, 7168, 8192]
    2048  = [for m in range(4096, 16385, 1024) : m]
    4096  = [for m in range(8192, 30721, 1024) : m]
    8192  = [for m in range(16384, 61441, 4096) : m]
    16384 = [for m in range(32768, 122881, 8192) : m]
  }

  container = merge(
    {
      name      = var.name
      image     = var.image
      essential = true
      environment = [
        for k in sort(keys(var.environment)) : { name = k, value = var.environment[k] }
      ]
      secrets = [
        for k in sort(keys(var.secrets)) : { name = k, valueFrom = var.secrets[k] }
      ]
      stopTimeout = var.stop_timeout
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.log_group_name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = var.name
        }
      }
    },
    var.command == null ? {} : { command = var.command },
    var.read_only_root_filesystem ? { readonlyRootFilesystem = true } : {},
    length(var.ephemeral_volumes) == 0 ? {} : {
      mountPoints = [for n in sort(keys(var.ephemeral_volumes)) : { sourceVolume = n, containerPath = var.ephemeral_volumes[n], readOnly = false }]
    },
    var.port == null ? {} : { portMappings = [{ containerPort = var.port, protocol = "tcp" }] },
    var.health_check_command == null ? {} : {
      healthCheck = {
        command     = var.health_check_command
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    },
  )
  container_json = jsonencode([local.container])
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.cpu)
  memory                   = tostring(var.memory)
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn
  container_definitions    = local.container_json
  tags                     = var.tags

  dynamic "volume" {
    for_each = var.ephemeral_volumes
    content {
      name = volume.key
    }
  }

  lifecycle {
    precondition {
      condition     = contains(lookup(local.fargate_memory, tostring(var.cpu), []), var.memory)
      error_message = "cpu/memory is not a valid Fargate combination."
    }
    precondition {
      condition     = !strcontains(local.container_json, "AGENTCORE_ALLOW_DEMO")
      error_message = "AGENTCORE_ALLOW_DEMO must not appear anywhere in the rendered container definition."
    }
    precondition {
      condition = alltrue([
        for arn in values(var.secrets) : !startswith(arn, var.rds_master_secret_arn_guard)
      ])
      error_message = "A workload must never be given the RDS master secret."
    }
  }
}

resource "aws_ecs_service" "this" {
  count = var.create_service ? 1 : 0

  name            = var.name
  cluster         = var.cluster_arn
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  dynamic "service_registries" {
    for_each = var.service_registry_arn == null ? [] : [var.service_registry_arn]
    content {
      registry_arn = service_registries.value
    }
  }

  tags = var.tags
}
