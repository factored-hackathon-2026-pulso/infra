resource "aws_sns_topic" "alarm" {
  name = "${var.name}-alarms"
  tags = var.tags
}
resource "aws_sns_topic_subscription" "alarm_email" {
  count     = var.alarm_email == null ? 0 : 1
  topic_arn = aws_sns_topic.alarm.arn
  protocol  = "email"
  endpoint  = var.alarm_email
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
