# Alarms for the outbox relay of a Core deployment. The log group is owned by the observability module
# (single owner, DR-86); this module only reads it through a metric filter. Queue and DLQ alarms live with the
# queues in `core_data`.

resource "aws_cloudwatch_log_metric_filter" "relay_failed" {
  name           = "${var.name_prefix}-relay-failed"
  log_group_name = var.log_group_name
  # The relay prints `published=N failed=N unknown=N` for every pass that moved or failed anything.
  pattern = "%failed=[1-9]%"

  metric_transformation {
    name          = "RelayFailedPasses"
    namespace     = var.metric_namespace
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
  namespace           = var.metric_namespace
  period              = 60
  statistic           = "Sum"
  threshold           = 1
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  tags                = var.tags
}

# Needs Container Insights on the cluster (the compute module enables it).
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
