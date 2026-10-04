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

run "bucket_policy_tls_and_no_wildcard_allow" {
  command = plan

  variables {
    loader_role_arns           = ["arn:aws:iam::111111111111:role/loader"]
    uploader_principal_arns    = ["arn:aws:iam::111111111111:user/human"]
    break_glass_principal_arns = ["arn:aws:iam::111111111111:role/admin"]
    s3_vpc_endpoint_id         = "vpce-0123456789abcdef0"
  }

  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Effect == "Deny" && try(s.Condition.Bool["aws:SecureTransport"], "") == "false"]) == 1
    error_message = "A TLS-only Deny is required."
  }
  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Effect == "Allow"]) == 0
    error_message = "The bucket policy must contain no Allow (same-account identity policies grant access)."
  }
  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyLandingReadOutsideVpce"]) == 1
    error_message = "VPC endpoint restriction for landing/ expected."
  }
  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyPiiReadToOthers" && contains(s.Condition.StringNotLike["aws:PrincipalArn"], "arn:aws:iam::111111111111:role/loader") && !contains(s.Condition.StringNotLike["aws:PrincipalArn"], "arn:aws:iam::111111111111:user/human")]) == 1
    error_message = "Only loader and break-glass may read landing/ and lake/bronze/; the uploader may not."
  }
}

run "no_vpce_means_no_vpce_statement" {
  command = plan
  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyLandingReadOutsideVpce"]) == 0
    error_message = "No endpoint id, no statement."
  }
  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyPiiReadToOthers"]) == 1
    error_message = "PII deny must exist even with empty lists (fails closed)."
  }
}

run "uploader_policy_is_put_only_on_landing" {
  command = apply
  assert {
    condition     = alltrue([for s in jsondecode(output.uploader_policy_json).Statement : s.Effect == "Allow" && !contains(flatten([s.Action]), "s3:GetObject") && !contains(flatten([s.Action]), "s3:DeleteObject") && !contains(flatten([s.Action]), "s3:*")])
    error_message = "Uploader may only put."
  }
  assert {
    condition     = alltrue([for s in jsondecode(output.uploader_policy_json).Statement : alltrue([for r in flatten([s.Resource]) : r != "*"])])
    error_message = "No wildcard resource."
  }
}

run "loader_policy_cannot_delete" {
  command = apply
  assert {
    condition     = alltrue([for s in jsondecode(output.loader_policy_json).Statement : !anytrue([for a in flatten([s.Action]) : can(regex("Delete|[*]", a))])])
    error_message = "Loader must not delete or hold wildcard actions."
  }
}

run "rds_is_private_encrypted_single_az_and_cheap" {
  command = plan

  assert {
    condition     = aws_db_instance.this.engine == "postgres" && startswith(aws_db_instance.this.engine_version, "16")
    error_message = "PostgreSQL 16."
  }
  assert {
    condition     = aws_db_instance.this.instance_class == "db.t4g.micro" && aws_db_instance.this.allocated_storage == 20 && aws_db_instance.this.storage_type == "gp3"
    error_message = "Smallest class, 20 GB gp3."
  }
  assert {
    condition     = aws_db_instance.this.storage_encrypted && !aws_db_instance.this.publicly_accessible && !aws_db_instance.this.multi_az
    error_message = "Encrypted, not public, single AZ."
  }
  assert {
    condition     = aws_db_instance.this.backup_retention_period == 7 && aws_db_instance.this.deletion_protection
    error_message = "7 day backups and deletion protection by default."
  }
  assert {
    condition     = contains(aws_db_instance.this.vpc_security_group_ids, "sg-0123456789abcdef0")
    error_message = "Database must use sg_db_id."
  }
  assert {
    condition     = toset(aws_db_subnet_group.this.subnet_ids) == toset(["subnet-aaaa1111", "subnet-bbbb2222"])
    error_message = "Database must sit in db_subnet_ids."
  }
  assert {
    condition     = aws_db_instance.this.manage_master_user_password != true
    error_message = "Master password lives in the single secret, not an RDS-managed one."
  }
}

run "parameter_group_limits_connections_forces_ssl_and_logs" {
  command = plan

  assert {
    condition     = one([for p in aws_db_parameter_group.this.parameter : p.value if p.name == "max_connections"]) == "40"
    error_message = "max_connections 40."
  }
  assert {
    condition     = one([for p in aws_db_parameter_group.this.parameter : p.value if p.name == "rds.force_ssl"]) == "1"
    error_message = "TLS forced."
  }
  assert {
    condition     = length([for p in aws_db_parameter_group.this.parameter : p if p.name == "log_min_duration_statement"]) == 1
    error_message = "Slow statement logging."
  }
}

run "cheapest_backup_and_no_protection_variables" {
  command = plan
  variables {
    db_backup_retention_days = 1
    db_deletion_protection   = false
    db_instance_class        = "db.t3.micro"
  }
  assert {
    condition     = aws_db_instance.this.backup_retention_period == 1 && !aws_db_instance.this.deletion_protection && aws_db_instance.this.instance_class == "db.t3.micro"
    error_message = "Variables must flow through."
  }
}
