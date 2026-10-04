# Hackathon single-host data profile (one RDS, one bucket, one secret, one KMS key). See README.md and docs/.

data "aws_caller_identity" "current" {}

locals {
  bucket_name = "${var.name_prefix}-data-${data.aws_caller_identity.current.account_id}"
  bucket_arn  = "arn:aws:s3:::${local.bucket_name}"
}

resource "aws_kms_key" "data" {
  description             = "${var.name_prefix} data key (S3 default encryption)"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.name_prefix}-data"
  target_key_id = aws_kms_key.data.key_id
}

resource "aws_s3_bucket" "data" {
  bucket = local.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_ownership_controls" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "data" {
  bucket = aws_s3_bucket.data.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  bucket = aws_s3_bucket.data.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  bucket                  = aws_s3_bucket.data.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_notification" "data" {
  count       = var.enable_eventbridge ? 1 : 0
  bucket      = aws_s3_bucket.data.id
  eventbridge = true
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  bucket = aws_s3_bucket.data.id

  rule {
    id     = "tmp-7d"
    status = "Enabled"
    filter {
      prefix = "tmp/"
    }
    expiration {
      days = 7
    }
  }

  rule {
    id     = "logs-90d"
    status = "Enabled"
    filter {
      prefix = "logs/"
    }
    expiration {
      days = 90
    }
  }

  dynamic "rule" {
    for_each = var.bronze_glacier_ir_days > 0 ? [1] : []
    content {
      id     = "bronze-glacier-ir"
      status = "Enabled"
      filter {
        prefix = "lake/bronze/"
      }
      transition {
        days          = var.bronze_glacier_ir_days
        storage_class = "GLACIER_IR"
      }
    }
  }

  rule {
    id     = "all-noncurrent-30d"
    status = "Enabled"
    filter {
      prefix = ""
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
