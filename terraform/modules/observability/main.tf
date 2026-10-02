resource "aws_cloudwatch_log_group" "api" {
  name              = "/pulso/${var.name}/api"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}
resource "aws_sns_topic" "alarm" {
  name = "${var.name}-alarms"
  tags = var.tags
}
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.name}-ecs-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  alarm_actions       = [aws_sns_topic.alarm.arn]
  dimensions = { ClusterName = var.cluster_name, ServiceName = var.service_name
  }
  tags = var.tags
}
resource "aws_cloudwatch_metric_alarm" "rds_cpu" {
  alarm_name          = "${var.name}-rds-cpu-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/RDS"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_alarm_threshold
  alarm_actions       = [aws_sns_topic.alarm.arn]
  dimensions = { DBInstanceIdentifier = var.db_instance_identifier
  }
  tags = var.tags
}
