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
    condition     = aws_db_instance.this[0].engine == "postgres" && startswith(aws_db_instance.this[0].engine_version, "16")
    error_message = "PostgreSQL 16."
  }
  assert {
    condition     = aws_db_instance.this[0].instance_class == "db.t4g.micro" && aws_db_instance.this[0].allocated_storage == 20 && aws_db_instance.this[0].storage_type == "gp3"
    error_message = "Smallest class, 20 GB gp3."
  }
  assert {
    condition     = aws_db_instance.this[0].storage_encrypted && !aws_db_instance.this[0].publicly_accessible && !aws_db_instance.this[0].multi_az
    error_message = "Encrypted, not public, single AZ."
  }
  assert {
    condition     = aws_db_instance.this[0].backup_retention_period == 7 && aws_db_instance.this[0].deletion_protection
    error_message = "7 day backups and deletion protection by default."
  }
  assert {
    condition     = contains(aws_db_instance.this[0].vpc_security_group_ids, "sg-0123456789abcdef0")
    error_message = "Database must use sg_db_id."
  }
  assert {
    condition     = toset(aws_db_subnet_group.this[0].subnet_ids) == toset(["subnet-aaaa1111", "subnet-bbbb2222"])
    error_message = "Database must sit in db_subnet_ids."
  }
  assert {
    condition     = aws_db_instance.this[0].manage_master_user_password != true
    error_message = "Master password lives in the single secret, not an RDS-managed one."
  }
}

run "parameter_group_limits_connections_forces_ssl_and_logs" {
  command = plan

  assert {
    condition     = one([for p in aws_db_parameter_group.this[0].parameter : p.value if p.name == "max_connections"]) == "40"
    error_message = "max_connections 40."
  }
  assert {
    condition     = one([for p in aws_db_parameter_group.this[0].parameter : p.value if p.name == "rds.force_ssl"]) == "1"
    error_message = "TLS forced."
  }
  assert {
    condition     = length([for p in aws_db_parameter_group.this[0].parameter : p if p.name == "log_min_duration_statement"]) == 1
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
    condition     = aws_db_instance.this[0].backup_retention_period == 1 && !aws_db_instance.this[0].deletion_protection && aws_db_instance.this[0].instance_class == "db.t3.micro"
    error_message = "Variables must flow through."
  }
}

run "one_secret_holds_every_sensitive_key" {
  command = plan

  assert {
    condition     = aws_secretsmanager_secret.this.name == "pulso-hk/hackathon"
    error_message = "One secret named <prefix>/hackathon."
  }
  assert {
    condition     = alltrue([for k in ["RDS_MASTER_PASSWORD", "CORE__AGENTCORE_REGISTRY_DSN", "CORE__AGENTCORE_EVAL_DSN", "CORE__AGENTCORE_LLM_GATEWAY_TOKEN", "GATEWAY__GATEWAY_TOKEN_ENGINE", "GATEWAY__JEV_API_KEY", "SUPPORT__CC_SESSION_SECRET", "SUPPORT__CC_TOTP_SECRET_KEY", "SUPPORT__CC_DATABASE_URL", "PULSO__PULSO_DATABASE_URL", "PULSO__PULSO_ADMIN_TOKEN", "PULSO__PULSO_DEBUG_TOKEN", "DB_PASSWORD_CORE_OWNER", "DB_PASSWORD_PULSO_LOADER"] : contains(keys(jsondecode(aws_secretsmanager_secret_version.this.secret_string)), k)])
    error_message = "Secret JSON is missing a documented key."
  }
  assert {
    condition     = jsondecode(aws_secretsmanager_secret_version.this.secret_string)["GATEWAY__OPENROUTER_API_KEY"] == "CHANGE_ME" && jsondecode(aws_secretsmanager_secret_version.this.secret_string)["CORE__AGENTCORE_REGISTRY_DSN"] != "CHANGE_ME"
    error_message = "Only provider keys are placeholders; the DSN is derived."
  }
  assert {
    condition     = alltrue([for k in keys(jsondecode(aws_secretsmanager_secret_version.this.secret_string)) : can(regex("^(CORE|GATEWAY|SUPPORT|PULSO|COMMON)__[A-Z0-9_]+$", k)) || can(regex("^DB_PASSWORD_[A-Z_]+$", k)) || k == "RDS_MASTER_PASSWORD"])
    error_message = "Host-consumed keys are <SERVICE>__<VAR> (the compute start script splits on the first double underscore); the rest are DB_PASSWORD_* and RDS_MASTER_PASSWORD."
  }
}

run "ssm_holds_only_non_secret_config_as_plain_strings" {
  command = plan

  assert {
    condition     = alltrue([for p in merge(aws_ssm_parameter.placeholder, aws_ssm_parameter.derived) : p.type == "String" && startswith(p.name, "/pulso/")])
    error_message = "Config parameters are standard String under /pulso/."
  }
  assert {
    condition     = length([for p in merge(aws_ssm_parameter.placeholder, aws_ssm_parameter.derived) : p if endswith(p.name, "/AGENTCORE_BLOB_BUCKET")]) == 1 && length([for p in merge(aws_ssm_parameter.placeholder, aws_ssm_parameter.derived) : p if endswith(p.name, "/PIPELINE_ROOT")]) == 1
    error_message = "Bucket-derived names expected."
  }
  assert {
    condition     = length([for p in merge(aws_ssm_parameter.placeholder, aws_ssm_parameter.derived) : p if can(regex("TOKEN|SECRET|PASSWORD|DSN|KEY", p.name))]) == 0
    error_message = "Secret-looking names must live in the secret, not SSM."
  }
  assert {
    condition     = alltrue([for p in merge(aws_ssm_parameter.placeholder, aws_ssm_parameter.derived) : can(regex("^/pulso/(core|platform|engine)/(common|core|gateway|support|pulso)/[A-Z0-9_]+$", p.name))])
    error_message = "Parameters live at /pulso/<workload>/<service>/<VAR>, matching the IAM path grant and the compute start script."
  }
  assert {
    condition     = output.ssm_prefix == "/pulso"
    error_message = "ssm_prefix."
  }
}

run "deploy_bundle_prefix_is_never_expired" {
  command = plan

  assert {
    condition     = alltrue([for r in aws_s3_bucket_lifecycle_configuration.data.rule : length(r.expiration) == 0 || contains(["tmp/", "logs/", "engine/build-src/", "engine/build-out/"], one(r.filter).prefix)])
    error_message = "Only tmp/, logs/ and the image-build scratch prefixes may expire current objects; engine/deploy/ (compose bundles) must not."
  }
}
run "loader_roles_are_exempt_from_the_vpce_restriction_but_others_are_not" {
  command = plan

  variables {
    loader_role_arns           = ["arn:aws:iam::111111111111:role/loader"]
    break_glass_principal_arns = ["arn:aws:iam::111111111111:user/admin"]
    s3_vpc_endpoint_id         = "vpce-0123456789abcdef0"
  }

  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyLandingReadOutsideVpce" && contains(s.Condition.StringNotLike["aws:PrincipalArn"], "arn:aws:iam::111111111111:role/loader") && contains(s.Condition.StringNotLike["aws:PrincipalArn"], "arn:aws:iam::111111111111:user/admin")]) == 1
    error_message = "Loader and break-glass principals are exempt from the endpoint-only landing/ read."
  }

  assert {
    condition     = length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Effect == "Allow"]) == 0 && length([for s in jsondecode(aws_s3_bucket_policy.data.policy).Statement : s if s.Sid == "DenyInsecureTransport"]) == 1
    error_message = "The policy stays deny-only and TLS-only."
  }
}

run "image_build_prefixes_expire_after_14_days" {
  command = plan

  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.data.rule : r if r.id == "build-src-14d" && one(r.filter).prefix == "engine/build-src/" && one(r.expiration).days == 14]) == 1
    error_message = "Source zips under engine/build-src/ expire after 14 days."
  }
  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.data.rule : r if r.id == "build-out-14d" && one(r.filter).prefix == "engine/build-out/" && one(r.expiration).days == 14]) == 1
    error_message = "Build records under engine/build-out/ expire after 14 days."
  }
}

# ---- free_plan ----

run "rds_mode_has_no_container_password_key" {
  command = apply

  assert {
    condition     = !contains(keys(jsondecode(aws_secretsmanager_secret_version.this.secret_string)), "DB__POSTGRES_PASSWORD")
    error_message = "DB__POSTGRES_PASSWORD only exists in container mode."
  }
}

run "origin_verify_secret_is_generated_and_rendered_to_every_host" {
  command = apply

  assert {
    condition     = contains(keys(jsondecode(aws_secretsmanager_secret_version.this.secret_string)), "COMMON__ORIGIN_VERIFY")
    error_message = "The CloudFront X-Origin-Verify value is in the single secret as COMMON__ORIGIN_VERIFY (common.env on every host, read by Caddy)."
  }
}

run "database_mode_is_validated" {
  command = plan
  variables {
    database_mode = "sqlite"
  }
  expect_failures = [var.database_mode]
}
