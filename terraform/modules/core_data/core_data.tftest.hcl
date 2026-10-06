mock_provider "aws" {
  # The default mock returns a random string for .json; apply validates it as policy JSON.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  name_prefix      = "test-core"
  blob_bucket_name = "test-core-blobs"
  alarm_actions    = []
  tags             = { Environment = "test" }
  consumers = {
    handoff-router = { event_types = ["handoff.created"] }
    analytics      = { event_types = [] }
  }
}

run "every_consumer_gets_a_queue_a_dead_letter_queue_and_alarms" {
  command = plan

  assert {
    condition     = length(aws_sqs_queue.consumer) == 2 && length(aws_sqs_queue.dlq) == 2
    error_message = "Each consumer needs a queue and a DLQ."
  }

  assert {
    condition     = length(aws_cloudwatch_metric_alarm.dlq_not_empty) == 2 && length(aws_cloudwatch_metric_alarm.queue_stale) == 2
    error_message = "Each consumer needs DLQ and staleness alarms."
  }
}

run "filters_apply_only_when_event_types_are_listed" {
  command = plan

  assert {
    condition     = aws_sns_topic_subscription.consumer["handoff-router"].filter_policy_scope == "MessageAttributes"
    error_message = "A listed event type must filter on message attributes."
  }

  assert {
    condition     = aws_sns_topic_subscription.consumer["analytics"].filter_policy == null
    error_message = "An empty event type list means every event."
  }
}

run "the_blob_bucket_is_versioned_private_and_encrypted" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_versioning.blobs.versioning_configuration).status == "Enabled"
    error_message = "Blob history must be kept."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.blobs.block_public_acls && aws_s3_bucket_public_access_block.blobs.restrict_public_buckets
    error_message = "The blob bucket must never be public."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.blobs.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Without a key the bucket uses AES256."
  }
}

run "a_key_selects_kms_for_the_bucket" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.blobs.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "A customer-managed key must select KMS."
  }
}

run "consumer_names_must_be_safe" {
  command = plan

  variables {
    consumers = { "Bad Name" = { event_types = [] } }
  }

  expect_failures = [var.consumers]
}

run "task_statements_stay_inside_the_workload_iam_rules" {
  command = apply

  assert {
    condition     = !strcontains(jsonencode(output.task_statements), "kms:") && !strcontains(jsonencode(output.task_statements), "secretsmanager:") && !strcontains(jsonencode(output.task_statements), "Delete")
    error_message = "Task statements must hold no kms:, secretsmanager: or delete permissions."
  }

  assert {
    condition     = strcontains(jsonencode(output.task_statements), "sns:Publish")
    error_message = "The relay must be able to publish."
  }
}

run "the_topic_is_unencrypted_unless_a_key_is_given" {
  command = plan

  assert {
    condition     = aws_sns_topic.events.kms_master_key_id == null
    error_message = "No key, no topic SSE: see the variable description."
  }
}
