resource "aws_ecs_cluster" "this" {
  name = "${var.name}-cluster"
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
  tags = var.tags
}
resource "aws_cloudwatch_log_group" "task" {
  name              = "/pulso/${var.name}/engine"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
resource "aws_ecs_task_definition" "this" {
  family                   = "${var.name}-engine"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.task_cpu
  memory                   = var.task_memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn
  container_definitions = jsonencode([{ name = "improvement-engine", image = var.image_digest, essential = true
  }])
}
resource "aws_ecs_service" "this" {
  name            = "${var.name}-engine"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.this.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"
  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }
  tags = var.tags
}
