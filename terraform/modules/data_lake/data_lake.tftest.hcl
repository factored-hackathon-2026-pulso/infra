mock_provider "aws" {}

variables {
  bucket_name                 = "test-data-lake"
  pipeline_task_role_arns     = ["arn:aws:iam::111111111111:role/test-data-pipeline-task"]
  restricted_reader_role_arns = ["arn:aws:iam::111111111111:role/test-agent-core-runtime"]
  masked_reader_role_arns     = ["arn:aws:iam::111111111111:role/test-masked-analyst"]
  analytics_reader_role_arns  = ["arn:aws:iam::111111111111:role/test-analytics"]
  evaluator_role_arns         = ["arn:aws:iam::111111111111:role/test-evaluator"]
  tags                        = { Environment = "test" }
}

run "the_lake_is_versioned_private_and_encrypted" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_versioning.lake.versioning_configuration).status == "Enabled"
    error_message = "Publication history must be kept."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.lake.block_public_acls && aws_s3_bucket_public_access_block.lake.restrict_public_buckets
    error_message = "The lake must never be public."
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.lake.rule).apply_server_side_encryption_by_default).sse_algorithm == "AES256"
    error_message = "Without a key the bucket uses AES256."
  }
}

run "a_kms_key_switches_the_bucket_to_sse_kms" {
  command = plan

  variables {
    kms_key_arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000"
  }

  assert {
    condition     = one(one(aws_s3_bucket_server_side_encryption_configuration.lake.rule).apply_server_side_encryption_by_default).sse_algorithm == "aws:kms"
    error_message = "A configured key must be used."
  }
}

run "each_zone_denies_everyone_not_on_its_list" {
  command = apply

  assert {
    condition = anytrue([
      for s in jsondecode(output.bucket_policy_json).Statement :
      s.Sid == "DenyReadBronzeExceptPipeline" && s.Effect == "Deny"
      && s.Condition.ArnNotEquals["aws:PrincipalArn"] == ["arn:aws:iam::111111111111:role/test-data-pipeline-task"]
    ])
    error_message = "bronze/ must be readable only by the pipeline task role."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.bucket_policy_json).Statement :
      s.Sid == "DenyReadEvaluatorAnswersExceptEvaluator" && s.Condition.ArnNotEquals["aws:PrincipalArn"] == ["arn:aws:iam::111111111111:role/test-evaluator"]
    ])
    error_message = "bronze_eval/ must be readable only by the evaluator."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.bucket_policy_json).Statement :
      s.Sid == "DenyReadRestrictedExceptRestrictedReaders" && s.Resource == ["${aws_s3_bucket.lake.arn}/publish/*/gold_restricted.duckdb"]
    ])
    error_message = "Only gold_restricted.duckdb is protected by the restricted list; the other publications are not."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.bucket_policy_json).Statement :
      s.Sid == "DenyInsecureTransport" && s.Condition.Bool["aws:SecureTransport"] == "false"
    ])
    error_message = "Plain HTTP must be refused."
  }
}

run "an_unconfigured_zone_fails_closed" {
  command = apply

  variables {
    pipeline_task_role_arns     = []
    restricted_reader_role_arns = []
    evaluator_role_arns         = []
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.bucket_policy_json).Statement :
      s.Sid == "DenyReadBronzeExceptPipeline" && s.Condition.ArnNotEquals["aws:PrincipalArn"] == ["arn:aws:iam::000000000000:role/data-lake-no-principal"]
    ])
    error_message = "An empty list must deny everyone, not allow everyone."
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.bucket_policy_json).Statement :
      s.Sid == "DenyReadRestrictedExceptRestrictedReaders" && s.Condition.ArnNotEquals["aws:PrincipalArn"] == ["arn:aws:iam::000000000000:role/data-lake-no-principal"]
    ])
    error_message = "No restricted reader configured means nobody reads personal data in clear."
  }
}

run "deletion_is_denied_unless_break_glass_is_listed" {
  command = apply

  assert {
    condition     = anytrue([for s in jsondecode(output.bucket_policy_json).Statement : s.Sid == "DenyDeletion" && !can(s.Condition)])
    error_message = "By default nobody deletes."
  }
}

run "break_glass_principals_are_the_only_exception_to_the_deletion_deny" {
  command = apply

  variables {
    admin_principal_arns = ["arn:aws:iam::111111111111:role/test-break-glass"]
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.bucket_policy_json).Statement :
      s.Sid == "DenyDeletionExceptBreakGlass" && s.Condition.ArnNotEquals["aws:PrincipalArn"] == ["arn:aws:iam::111111111111:role/test-break-glass"]
    ])
    error_message = "Only the listed principals may delete."
  }
}

run "each_reader_gets_only_its_own_zone" {
  command = apply

  assert {
    condition     = !strcontains(jsonencode(output.analytics_reader_statements), "gold_restricted") && !strcontains(jsonencode(output.analytics_reader_statements), "gold_masked") && !strcontains(jsonencode(output.analytics_reader_statements), "bronze")
    error_message = "Analytics readers must never be granted restricted, masked or bronze data."
  }

  assert {
    condition     = strcontains(jsonencode(output.restricted_reader_statements), "gold_restricted.duckdb") && !strcontains(jsonencode(output.restricted_reader_statements), "bronze") && !strcontains(jsonencode(output.restricted_reader_statements), "gold_masked")
    error_message = "Restricted readers get the restricted publication and nothing from bronze."
  }

  assert {
    condition     = !strcontains(jsonencode(output.masked_reader_statements), "gold_restricted") && strcontains(jsonencode(output.masked_reader_statements), "gold_masked.duckdb")
    error_message = "Masked readers must never be granted the restricted publication."
  }

  assert {
    condition     = !strcontains(jsonencode(output.evaluator_reader_statements), "publish") && strcontains(jsonencode(output.evaluator_reader_statements), "bronze_eval")
    error_message = "The evaluator reads only the answers."
  }
}

run "the_pipeline_task_can_write_every_zone_but_read_only_bronze" {
  command = apply

  assert {
    condition     = !strcontains(jsonencode(output.pipeline_task_statements), "Delete") && !strcontains(jsonencode(output.pipeline_task_statements), "kms:")
    error_message = "The task never deletes and holds no kms: actions (ADR 0003)."
  }

  assert {
    condition     = length([for s in output.pipeline_task_statements : s if contains(s.Action, "s3:GetObject")]) == 1 && !strcontains(jsonencode([for s in output.pipeline_task_statements : s if contains(s.Action, "s3:GetObject")]), "bronze_eval")
    error_message = "The only read grant is on bronze/, never on the evaluator's answers or on publications."
  }
}

run "every_statement_is_acceptable_to_workload_iam" {
  command = apply

  assert {
    condition = alltrue([
      for s in concat(
        output.pipeline_task_statements, output.restricted_reader_statements, output.masked_reader_statements,
        output.analytics_reader_statements, output.evaluator_reader_statements
      ) : !anytrue([for a in s.Action : can(regex("^(\\*|[a-z0-9-]+:\\*|iam:|sts:|secretsmanager:|kms:)", lower(a)))])
    ])
    error_message = "workload_iam refuses wildcards, iam:, sts:, secretsmanager: and kms: in task_statements."
  }
}

run "retention_is_off_until_the_data_owner_sets_it" {
  command = plan

  assert {
    condition     = length([for r in aws_s3_bucket_lifecycle_configuration.lake.rule : r if r.id == "expire-old-publications"]) == 0
    error_message = "No expiry rule without an explicit retention."
  }
}

run "retention_targets_publish_runs_and_never_the_pointer" {
  command = plan

  variables {
    publish_retention_days = 180
  }

  assert {
    condition = anytrue([
      for r in aws_s3_bucket_lifecycle_configuration.lake.rule :
      r.id == "expire-old-publications" && one(r.filter).prefix == "publish/run-" && one(r.expiration).days == 180
    ])
    error_message = "Expiry must match publish/run- only, so publish/latest.json survives."
  }
}

run "a_tiny_retention_is_refused" {
  command = plan

  variables {
    publish_retention_days = 1
  }

  expect_failures = [var.publish_retention_days]
}
