mock_provider "aws" {}

variables {
  name_prefix        = "test-core"
  cluster_name       = "test-pulso"
  relay_service_name = "pulso-core-relay"
  log_group_name     = "/pulso/test/pulso-core-relay"
  alarm_actions      = []
  tags               = { Environment = "test" }
}

run "the_relay_filter_reads_an_existing_log_group_and_never_creates_one" {
  command = plan

  assert {
    condition     = aws_cloudwatch_log_metric_filter.relay_failed.log_group_name == var.log_group_name
    error_message = "The log group has a single owner (DR-86)."
  }
}

run "a_stopped_relay_alarms_even_without_metrics" {
  command = plan

  assert {
    condition     = aws_cloudwatch_metric_alarm.relay_running.treat_missing_data == "breaching"
    error_message = "Missing RunningTaskCount means the relay is down."
  }
}
