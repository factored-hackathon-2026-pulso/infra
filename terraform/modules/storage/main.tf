resource "aws_s3_bucket" "artifact" {
  bucket = var.artifact_bucket_name
}
resource "aws_s3_bucket" "source" {
  bucket = var.source_bucket_name
}
locals {
  buckets = {
    artifact = {
      id  = aws_s3_bucket.artifact.id
      arn = aws_s3_bucket.artifact.arn
    }
    source = {
      id  = aws_s3_bucket.source.id
      arn = aws_s3_bucket.source.arn
    }
  }
}
data "aws_iam_policy_document" "require_kms" {
  for_each = local.buckets

  statement {
    sid       = "DenyMissingSseKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = ["true"]
    }
  }
  statement {
    sid       = "DenyNonKmsObjectEncryption"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["aws:kms"]
    }
  }
  statement {
    sid       = "DenyWrongSseKmsKey"
    effect    = "Deny"
    actions   = ["s3:PutObject"]
    resources = ["${each.value.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotEqualsIfExists"
      variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
      values   = [var.kms_key_arn]
    }
  }
}
resource "aws_s3_bucket_policy" "require_kms" {
  for_each = local.buckets

  bucket = each.value.id
  policy = data.aws_iam_policy_document.require_kms[each.key].json
}
resource "aws_s3_bucket_server_side_encryption_configuration" "artifact" {
  bucket = aws_s3_bucket.artifact.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}
resource "aws_s3_bucket_server_side_encryption_configuration" "source" {
  bucket = aws_s3_bucket.source.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}
resource "aws_s3_bucket_public_access_block" "artifact" {
  bucket                  = aws_s3_bucket.artifact.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_public_access_block" "source" {
  bucket                  = aws_s3_bucket.source.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_versioning" "artifact" {
  bucket = aws_s3_bucket.artifact.id
  versioning_configuration {
    status = "Enabled"
  }
}
resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.source.id
  versioning_configuration {
    status = "Enabled"
  }
}
