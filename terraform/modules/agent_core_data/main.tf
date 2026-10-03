# Data plane that lets Agent Core scale out (ADR 0005, agent-core ADR 0023):
#   - an S3 bucket for the registry's content-addressed blobs,
#   - an SNS topic that carries the outbound events published by the outbox relay,
#   - one SQS queue (with a dead-letter queue) per consumer, subscribed with an event_type filter.

locals {
  sse_algorithm = var.kms_key_arn == "" ? "AES256" : "aws:kms"
}

# --- Registry blobs ----------------------------------------------------------------------------------------

resource "aws_s3_bucket" "blobs" {
  bucket = var.blob_bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "blobs" {
  bucket = aws_s3_bucket.blobs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "blobs" {
  bucket = aws_s3_bucket.blobs.id
  rule {
    bucket_key_enabled = var.kms_key_arn != ""
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_algorithm
      kms_master_key_id = var.kms_key_arn == "" ? null : var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "blobs" {
  bucket                  = aws_s3_bucket.blobs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "blobs" {
  bucket = aws_s3_bucket.blobs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "blobs" {
  bucket = aws_s3_bucket.blobs.id

  rule {
    id     = "abort-incomplete-upload"
    status = "Enabled"
    filter {
      prefix = ""
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # Blobs are written once per hash, so noncurrent versions only exist after a manual overwrite or a delete
  # marker by an administrator.
  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"
    filter {
      prefix = ""
    }
    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_days
    }
  }
}

# Integrity of the registry now rests on the hash being verified at read time and on blobs never disappearing
# (the foreign key to reg_blobs is dropped): deny deletes to everyone except the listed break-glass principals,
# and refuse plain HTTP.
data "aws_iam_policy_document" "blobs" {
  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.blobs.arn, "${aws_s3_bucket.blobs.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  statement {
    sid       = "DenyBlobDeletion"
    effect    = "Deny"
    actions   = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
    resources = ["${aws_s3_bucket.blobs.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    dynamic "condition" {
      for_each = length(var.blob_admin_principal_arns) == 0 ? [] : [1]
      content {
        test     = "ArnNotEquals"
        variable = "aws:PrincipalArn"
        values   = var.blob_admin_principal_arns
      }
    }
  }
}

resource "aws_s3_bucket_policy" "blobs" {
  bucket     = aws_s3_bucket.blobs.id
  policy     = data.aws_iam_policy_document.blobs.json
  depends_on = [aws_s3_bucket_public_access_block.blobs]
}

# --- Outbound events -----------------------------------------------------------------------------------------

resource "aws_sns_topic" "events" {
  name              = "${var.name_prefix}-events"
  kms_master_key_id = var.sns_kms_key_id
  tags              = var.tags
}

resource "aws_sqs_queue" "dlq" {
  for_each                  = var.consumers
  name                      = "${var.name_prefix}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days to investigate
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "consumer" {
  for_each                   = var.consumers
  name                       = "${var.name_prefix}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = var.queue_retention_seconds
  receive_wait_time_seconds  = 20 # long polling
  sqs_managed_sse_enabled    = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  })

  tags = var.tags
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each  = var.consumers
  queue_url = aws_sqs_queue.dlq[each.key].id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.consumer[each.key].arn]
  })
}

data "aws_iam_policy_document" "queue" {
  for_each = var.consumers

  statement {
    sid       = "AllowTopicToSend"
    effect    = "Allow"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.consumer[each.key].arn]
    principals {
      type        = "Service"
      identifiers = ["sns.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_sns_topic.events.arn]
    }
  }
}

resource "aws_sqs_queue_policy" "consumer" {
  for_each  = var.consumers
  queue_url = aws_sqs_queue.consumer[each.key].id
  policy    = data.aws_iam_policy_document.queue[each.key].json
}

resource "aws_sns_topic_subscription" "consumer" {
  for_each             = var.consumers
  topic_arn            = aws_sns_topic.events.arn
  protocol             = "sqs"
  endpoint             = aws_sqs_queue.consumer[each.key].arn
  raw_message_delivery = true # the body is the event JSON; type and id arrive as message attributes

  # An empty list means "every event type".
  filter_policy       = length(each.value.event_types) == 0 ? null : jsonencode({ event_type = each.value.event_types })
  filter_policy_scope = length(each.value.event_types) == 0 ? null : "MessageAttributes"

  depends_on = [aws_sqs_queue_policy.consumer]
}

# --- Alarms --------------------------------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  for_each            = var.consumers
  alarm_name          = "${var.name_prefix}-${each.key}-dlq-not-empty"
  alarm_description   = "Events for ${each.key} exhausted their retries and sit in the dead-letter queue."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  dimensions          = { QueueName = aws_sqs_queue.dlq[each.key].name }
  tags                = var.tags
}

resource "aws_cloudwatch_metric_alarm" "queue_stale" {
  for_each            = var.consumers
  alarm_name          = "${var.name_prefix}-${each.key}-oldest-message-age"
  alarm_description   = "The oldest event for ${each.key} has waited too long: the consumer is down or slow."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.max_message_age_seconds
  treat_missing_data  = "notBreaching"
  alarm_actions       = var.alarm_actions
  dimensions          = { QueueName = aws_sqs_queue.consumer[each.key].name }
  tags                = var.tags
}
