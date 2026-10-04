mock_provider "aws" {}
mock_provider "random" {}

variables {
  name_prefix   = "pulso-hk"
  region        = "us-east-1"
  vpc_id        = "vpc-0123456789abcdef0"
  db_subnet_ids = ["subnet-aaaa1111", "subnet-bbbb2222"]
  sg_db_id      = "sg-0123456789abcdef0"
}

run "bucket_is_private_versioned_and_encrypted" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_versioning.data.versioning_configuration).status == "Enabled"
    error_message = "Bucket must be versioned."
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.data.block_public_acls && aws_s3_bucket_public_access_block.data.block_public_policy && aws_s3_bucket_public_access_block.data.ignore_public_acls && aws_s3_bucket_public_access_block.data.restrict_public_buckets
    error_message = "All four public access blocks must be on."
  }
  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.data.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "SSE-KMS expected."
  }
}

run "kms_key_rotates_bucket_key_on_ownership_enforced" {
  command = plan

  assert {
    condition     = aws_kms_key.data.enable_key_rotation
    error_message = "CMK rotation must be on."
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.data.rule).bucket_key_enabled
    error_message = "Bucket key must be on to cut KMS cost."
  }
  assert {
    condition     = one(aws_s3_bucket_ownership_controls.data.rule).object_ownership == "BucketOwnerEnforced"
    error_message = "ACLs must be disabled."
  }
  assert {
    condition     = length(aws_s3_bucket_notification.data) == 0
    error_message = "EventBridge off by default."
  }
}

run "lifecycle_per_prefix" {
  command = plan

  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.data.rule : r if r.id == "tmp-7d" && one(r.expiration).days == 7]) == 1
    error_message = "tmp/ expires after 7 days."
  }
  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.data.rule : r if r.id == "logs-90d" && one(r.expiration).days == 90]) == 1
    error_message = "logs/ expires after 90 days."
  }
  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.data.rule : r if r.id == "all-noncurrent-30d" && one(r.noncurrent_version_expiration).noncurrent_days == 30 && one(r.abort_incomplete_multipart_upload).days_after_initiation == 7]) == 1
    error_message = "Noncurrent versions 30d and multipart abort."
  }
  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.data.rule : r if r.id == "bronze-glacier-ir"]) == 0
    error_message = "Glacier IR transition is off by default."
  }
}

run "bronze_glacier_optional" {
  command = plan
  variables {
    bronze_glacier_ir_days = 90
  }
  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.data.rule : r if r.id == "bronze-glacier-ir"]) == 1
    error_message = "Glacier IR rule expected when enabled."
  }
}
