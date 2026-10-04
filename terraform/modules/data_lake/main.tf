# Lake bucket of the data-pipeline workload (ADR 0006).
#
# DuckDB has no roles, so the protection of the personal data in these files is enforced here and nowhere else.
# One bucket, five zones by key prefix. Two layers per zone, so a mistake in one is not enough:
#   - identity statements (outputs below) that each role attaches, and
#   - Deny statements in the bucket policy that block every principal that is not on the zone's list,
#     including a role that happens to hold s3:* in its own policy.
#
#   bronze/                                  pipeline task only      faithful copy of the sources, personal data
#   bronze_eval/                             evaluator only          labels and timeline
#   publish/<run>/gold_restricted.duckdb     restricted readers      personal data in clear, classified
#   publish/<run>/gold_masked.duckdb         masked readers          masked personal data
#   publish/<run>/gold_analytics.duckdb      analytics readers       pseudonymised; also parquet/
#   publish/latest.json, release.json,       every reader            pointer, lineage and the classification
#   field_classification.json
#
# The re-identification map (pseudonym_map) is never written to S3 (data-pipeline publishes without it).

locals {
  sse_algorithm = var.kms_key_arn == "" ? "AES256" : "aws:kms"

  # An empty list would make "deny everyone not on the list" an invalid or vacuous condition. A principal that
  # cannot exist keeps the Deny active, so an unconfigured zone fails closed instead of open.
  no_principal = ["arn:aws:iam::000000000000:role/data-lake-no-principal"]

  task_arns       = length(var.pipeline_task_role_arns) == 0 ? local.no_principal : var.pipeline_task_role_arns
  restricted_arns = length(var.restricted_reader_role_arns) == 0 ? local.no_principal : var.restricted_reader_role_arns
  masked_arns     = length(var.masked_reader_role_arns) == 0 ? local.no_principal : var.masked_reader_role_arns
  evaluator_arns  = length(var.evaluator_role_arns) == 0 ? local.no_principal : var.evaluator_role_arns

  arn = aws_s3_bucket.lake.arn

  # Objects every reader of a publication needs.
  common_read = [
    "${local.arn}/publish/latest.json",
    "${local.arn}/publish/*/release.json",
    "${local.arn}/publish/*/field_classification.json",
  ]
}

resource "aws_s3_bucket" "lake" {
  bucket = var.bucket_name
  tags   = var.tags
}

resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    bucket_key_enabled = var.kms_key_arn != ""
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.sse_algorithm
      kms_master_key_id = var.kms_key_arn == "" ? null : var.kms_key_arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "lake" {
  bucket = aws_s3_bucket.lake.id

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

  # Only when the data owner sets a retention. The prefix is publish/run-, so publish/latest.json is never matched.
  # bronze/ has no rule on purpose: its retention is an open decision (ADR 0006, open questions).
  dynamic "rule" {
    for_each = var.publish_retention_days == null ? [] : [var.publish_retention_days]
    content {
      id     = "expire-old-publications"
      status = "Enabled"
      filter {
        prefix = "publish/run-"
      }
      expiration {
        days = rule.value
      }
    }
  }
}

locals {
  bucket_policy = {
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid       = "DenyInsecureTransport"
          Effect    = "Deny"
          Principal = "*"
          Action    = "s3:*"
          Resource  = [local.arn, "${local.arn}/*"]
          Condition = { Bool = { "aws:SecureTransport" = "false" } }
        },
        {
          Sid       = "DenyReadBronzeExceptPipeline"
          Effect    = "Deny"
          Principal = "*"
          Action    = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource  = ["${local.arn}/bronze/*"]
          Condition = { ArnNotEquals = { "aws:PrincipalArn" = local.task_arns } }
        },
        {
          Sid       = "DenyReadEvaluatorAnswersExceptEvaluator"
          Effect    = "Deny"
          Principal = "*"
          Action    = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource  = ["${local.arn}/bronze_eval/*"]
          Condition = { ArnNotEquals = { "aws:PrincipalArn" = local.evaluator_arns } }
        },
        {
          Sid       = "DenyReadRestrictedExceptRestrictedReaders"
          Effect    = "Deny"
          Principal = "*"
          Action    = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource  = ["${local.arn}/publish/*/gold_restricted.duckdb"]
          Condition = { ArnNotEquals = { "aws:PrincipalArn" = local.restricted_arns } }
        },
        {
          Sid       = "DenyReadMaskedExceptMaskedReaders"
          Effect    = "Deny"
          Principal = "*"
          Action    = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource  = ["${local.arn}/publish/*/gold_masked.duckdb"]
          Condition = { ArnNotEquals = { "aws:PrincipalArn" = local.masked_arns } }
        },
      ],
      # Publications are immutable: nobody deletes, except the listed break-glass principals. Two for-expressions
      # instead of a conditional, because Terraform needs both branches of a conditional to have the same type.
      [for _ in range(length(var.admin_principal_arns) == 0 ? 1 : 0) : {
        Sid       = "DenyDeletion"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource  = ["${local.arn}/*"]
      }],
      [for _ in range(length(var.admin_principal_arns) == 0 ? 0 : 1) : {
        Sid       = "DenyDeletionExceptBreakGlass"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource  = ["${local.arn}/*"]
        Condition = { ArnNotEquals = { "aws:PrincipalArn" = var.admin_principal_arns } }
      }],
    )
  }
}

resource "aws_s3_bucket_policy" "lake" {
  bucket     = aws_s3_bucket.lake.id
  policy     = jsonencode(local.bucket_policy)
  depends_on = [aws_s3_bucket_public_access_block.lake]
}
