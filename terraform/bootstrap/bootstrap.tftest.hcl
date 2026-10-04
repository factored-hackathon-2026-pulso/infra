mock_provider "aws" {}

variables {
  aws_region        = "test-region-1"
  state_bucket_name = "test-pulso-tfstate"
}

run "state_bucket_is_private_versioned_encrypted_and_tls_only" {
  command = apply

  assert {
    condition     = aws_s3_bucket_versioning.state.versioning_configuration[0].status == "Enabled"
    error_message = "State must be versioned so a bad write can be rolled back."
  }

  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.state.rule).apply_server_side_encryption_by_default[0].sse_algorithm == "AES256"
    error_message = "State must be encrypted at rest."
  }

  assert {
    condition = alltrue([
      aws_s3_bucket_public_access_block.state.block_public_acls,
      aws_s3_bucket_public_access_block.state.block_public_policy,
      aws_s3_bucket_public_access_block.state.ignore_public_acls,
      aws_s3_bucket_public_access_block.state.restrict_public_buckets,
    ])
    error_message = "State bucket must block all public access."
  }

  assert {
    condition     = strcontains(aws_s3_bucket_policy.state.policy, "aws:SecureTransport")
    error_message = "State bucket policy must deny non-TLS access."
  }

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false
    error_message = "State bucket must never be force-destroyed."
  }
}

run "state_bucket_name_is_required_and_validated" {
  command = plan

  variables {
    state_bucket_name = "Bad_Name"
  }

  expect_failures = [var.state_bucket_name]
}

run "backend_snippet_uses_native_locking" {
  command = apply

  assert {
    condition     = strcontains(output.backend_hcl, "use_lockfile = true") && strcontains(output.backend_hcl, "encrypt      = true")
    error_message = "The emitted backend config must use native S3 locking and encryption."
  }
}
