# Alarms for the Agent Core workload (ADR 0005). Queue and DLQ alarms live with the queues
# (agent_core_data); these cover the API, the relay and the scheduled sweep.

resource "aws_cloudwatch_metric_alarm" "target_5xx" {
  alarm_name          = "${var.name_prefix}-5xx"
  alarm_description   = "Agent Core tasks are answering 5xx."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = var.target_5xx_threshold
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  dimensions = {
    LoadBalancer = var.load_balancer_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "latency_p95" {
  alarm_name          = "${var.name_prefix}-latency-p95"
  alarm_description   = "p95 turn latency is above the threshold (the LLM is the usual cause)."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "TargetResponseTime"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  extended_statistic  = "p95"
  threshold           = var.latency_p95_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  dimensions = {
    LoadBalancer = var.load_balancer_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "unhealthy_hosts" {
  alarm_name          = "${var.name_prefix}-unhealthy-hosts"
  alarm_description   = "Targets behind the load balancer are failing /healthz."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "UnHealthyHostCount"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  dimensions = {
    LoadBalancer = var.load_balancer_arn_suffix
    TargetGroup  = var.target_group_arn_suffix
  }
  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "service_cpu" {
  alarm_name          = "${var.name_prefix}-cpu-high"
  alarm_description   = "Sustained CPU at the autoscaling ceiling: raise serve_max_count or the task size."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 300
  statistic           = "Average"
  threshold           = 85
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.service_name
  }
  tags = var.tags
}

# The relay prints `published=N failed=N unknown=N` for every pass that moved or failed anything.
# `failed` > 0 sustained means a message cannot be projected or published (agent-core ADR 0023 risks).
resource "aws_cloudwatch_log_metric_filter" "relay_failed" {
  name           = "${var.name_prefix}-relay-failed"
  log_group_name = var.log_group_name
  pattern        = "%failed=[1-9]%"

  metric_transformation {
    name          = "RelayFailedPasses"
    namespace     = "Pulso/AgentCore"
    value         = "1"
    default_value = "0"
  }
}

resource "aws_cloudwatch_metric_alarm" "relay_failed" {
  alarm_name          = "${var.name_prefix}-relay-failing"
  alarm_description   = "The outbox relay keeps failing to deliver events; handoffs may not reach their queue."
  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 5
  datapoints_to_alarm = 5
  metric_name         = "RelayFailedPasses"
  namespace           = "Pulso/AgentCore"
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "relay_running" {
  alarm_name          = "${var.name_prefix}-relay-not-running"
  alarm_description   = "No relay task is running: the outbox is not being delivered."
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  metric_name         = "RunningTaskCount"
  namespace           = "ECS/ContainerInsights"
  period              = 60
  statistic           = "Minimum"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_actions
  dimensions = {
    ClusterName = var.cluster_name
    ServiceName = var.relay_service_name
  }
  tags = var.tags
}
