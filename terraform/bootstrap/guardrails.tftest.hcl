mock_provider "aws" {}

variables {
  aws_region        = "test-region-1"
  state_bucket_name = "test-pulso-tfstate"
}

run "budget_alarm_needs_an_email_and_uses_the_variables" {
  command = apply

  variables {
    budget_alert_email = "ops@example.invalid"
    monthly_budget_usd = 150
  }

  assert {
    condition     = length(aws_budgets_budget.monthly) == 1 && aws_budgets_budget.monthly[0].limit_amount == "150"
    error_message = "A monthly cost budget must exist with the configured limit."
  }

  assert {
    condition     = length(aws_budgets_budget.monthly[0].notification) == 3
    error_message = "Budget must alert at 50, 80 and 100 percent (AWS-06)."
  }
}

run "no_email_means_no_budget_and_nothing_is_hard_coded" {
  command = apply

  assert {
    condition     = length(aws_budgets_budget.monthly) == 0
    error_message = "Without an email variable no budget is declared; there is no default address."
  }
}

run "bad_email_is_rejected" {
  command = plan

  variables {
    budget_alert_email = "not-an-email"
  }

  expect_failures = [var.budget_alert_email]
}

run "account_alias_only_when_set" {
  command = apply

  variables {
    account_alias = "pulso-test-alias"
  }

  assert {
    condition     = aws_iam_account_alias.this[0].account_alias == "pulso-test-alias"
    error_message = "Alias must come from the variable."
  }
}

run "cloudtrail_is_private_validated_and_multi_region" {
  command = apply

  assert {
    condition     = aws_cloudtrail.main[0].enable_log_file_validation && aws_cloudtrail.main[0].is_multi_region_trail
    error_message = "Trail needs log file validation and multi-region coverage."
  }

  assert {
    condition     = aws_s3_bucket_public_access_block.trail[0].block_public_acls && aws_s3_bucket_public_access_block.trail[0].restrict_public_buckets
    error_message = "Trail bucket must block public access."
  }
}

run "cloudtrail_can_be_switched_off" {
  command = apply

  variables {
    cloudtrail_enabled = false
  }

  assert {
    condition     = length(aws_cloudtrail.main) == 0
    error_message = "cloudtrail_enabled=false must remove the trail."
  }
}

run "account_password_and_s3_account_guardrails" {
  command = apply

  assert {
    condition     = aws_s3_account_public_access_block.account.block_public_policy && aws_s3_account_public_access_block.account.restrict_public_buckets
    error_message = "Account-level S3 public access block must be on."
  }
}
