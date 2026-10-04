# Zero-input contract: the human runs bootstrap in a fresh account without choosing anything.
mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "000000000000"
    }
  }
}

run "no_inputs_are_required_and_the_state_bucket_name_is_derived" {
  command = apply

  assert {
    condition     = aws_s3_bucket.state.bucket == "pulso-prod-tfstate-000000000000"
    error_message = "Without state_bucket_name the bucket is pulso-prod-tfstate-<account id>."
  }

  assert {
    condition     = var.aws_region == "us-east-1"
    error_message = "Single-region prod defaults to us-east-1."
  }
}

run "an_explicit_state_bucket_name_still_wins" {
  command = apply

  variables {
    state_bucket_name = "my-custom-state"
  }

  assert {
    condition     = aws_s3_bucket.state.bucket == "my-custom-state"
    error_message = "state_bucket_name overrides the derived name."
  }
}

run "costly_or_optional_extras_are_off_by_default" {
  command = apply

  assert {
    condition     = length(aws_cloudtrail.main) == 0 && length(aws_budgets_budget.monthly) == 0 && length(aws_iam_role.deploy) == 0 && length(aws_iam_openid_connect_provider.github) == 0
    error_message = "CloudTrail, budget and the GitHub OIDC role must be off unless explicitly enabled."
  }
}

run "ecr_prefix_is_prod_and_backend_snippet_uses_the_derived_bucket" {
  command = apply

  assert {
    condition     = output.ecr_repository_names["pulso-engine"] == "prod/pulso-engine" && strcontains(output.backend_hcl, "pulso-prod-tfstate-000000000000")
    error_message = "ECR prefix defaults to prod and the backend snippet uses the derived bucket."
  }
}
