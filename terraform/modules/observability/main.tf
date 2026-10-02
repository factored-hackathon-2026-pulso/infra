resource "aws_cloudwatch_log_group" "this" {
  name              = "/pulso/${var.tags["Environment"]}/${var.service_name}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  alarm_name          = "${var.tags["Environment"]}-pulso-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 80
  treat_missing_data  = "missing"
  alarm_actions       = var.alarm_actions
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }
  tags = var.tags
}
