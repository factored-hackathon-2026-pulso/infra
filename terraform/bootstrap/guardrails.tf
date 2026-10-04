data "aws_caller_identity" "current" {}

locals {
  budget_enabled = var.budget_alert_email != ""
}

resource "aws_s3_account_public_access_block" "account" {
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_account_alias" "this" {
  count         = var.account_alias == "" ? 0 : 1
  account_alias = var.account_alias
}

resource "aws_budgets_budget" "monthly" {
  count        = local.budget_enabled ? 1 : 0
  name         = "pulso-monthly-cost"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.budget_alert_email]
    }
  }

  tags = var.tags
}

# CloudTrail: management events only (cheap), private bucket, log file validation.
resource "aws_s3_bucket" "trail" {
  count         = var.cloudtrail_enabled ? 1 : 0
  bucket        = "${var.state_bucket_name}-trail"
  force_destroy = false
  tags          = var.tags
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = var.cloudtrail_enabled ? 1 : 0
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count  = var.cloudtrail_enabled ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count  = var.cloudtrail_enabled ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {
      prefix = ""
    }
    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket_policy" "trail" {
  count  = var.cloudtrail_enabled ? 1 : 0
  bucket = aws_s3_bucket.trail[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail[0].arn
      },
      {
        Sid       = "Write"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = { StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" } }
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.trail[0].arn, "${aws_s3_bucket.trail[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.trail]
}

resource "aws_cloudtrail" "main" {
  count                         = var.cloudtrail_enabled ? 1 : 0
  name                          = "pulso-management-events"
  s3_bucket_name                = aws_s3_bucket.trail[0].id
  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  tags                          = var.tags
  depends_on                    = [aws_s3_bucket_policy.trail]
}
