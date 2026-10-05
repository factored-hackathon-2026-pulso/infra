mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/hk-boundary"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/hk-mock"
    }
  }
}

variables {
  name                         = "hk"
  region                       = "us-east-1"
  ssm_parameter_path_prefix    = "/hk"
  s3_bucket_name               = "hk-data-bucket"
  core_s3_prefixes             = ["core/blobs"]
  engine_s3_prefixes           = ["engine"]
  engine_lake_read_prefixes    = ["lake/gold_masked", "lake/gold_analytics"]
  ecr_repository_arns_core     = ["arn:aws:ecr:us-east-1:123456789012:repository/hk/core"]
  ecr_repository_arns_platform = ["arn:aws:ecr:us-east-1:123456789012:repository/hk/platform"]
  ecr_repository_arns_engine   = ["arn:aws:ecr:us-east-1:123456789012:repository/hk/engine"]
  secret_arn                   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:hk/hackathon-AbCdEf"
  kms_key_arn                  = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  tags                         = { Environment = "hackathon" }
}

run "no_loader_role_by_default" {
  command = apply

  assert {
    condition     = length(aws_iam_role.loader) == 0 && output.loader_role_arn == ""
    error_message = "The loader role exists only with loader_role_enabled."
  }
  assert {
    condition     = !anytrue([for w in ["core", "platform", "engine"] : strcontains(aws_iam_policy.host[w].policy, "sts:AssumeRole")]) && !strcontains(aws_iam_policy.boundary.policy, "sts:AssumeRole")
    error_message = "Without the loader nobody may assume a role."
  }
}

run "loader_role_is_assumable_only_by_the_engine_host_with_the_external_id" {
  command = apply
  variables {
    loader_role_enabled = true
    loader_external_id  = "hk-loader-123456789012"
  }

  assert {
    condition = (
      length(jsondecode(aws_iam_role.loader[0].assume_role_policy).Statement) == 1 &&
      jsondecode(aws_iam_role.loader[0].assume_role_policy).Statement[0].Principal.AWS == aws_iam_role.host["engine"].arn &&
      jsondecode(aws_iam_role.loader[0].assume_role_policy).Statement[0].Condition.StringEquals["sts:ExternalId"] == "hk-loader-123456789012" &&
      jsondecode(aws_iam_role.loader[0].assume_role_policy).Statement[0].Action == "sts:AssumeRole"
    )
    error_message = "Trust: exactly the engine host role, with the external id, nothing else."
  }
  assert {
    condition     = aws_iam_role.loader[0].name == "hk-loader" && aws_iam_role.loader[0].max_session_duration == 3600 && aws_iam_role.loader[0].permissions_boundary == aws_iam_policy.boundary.arn
    error_message = "Fixed name, one-hour sessions, the host permissions boundary."
  }
  assert {
    condition = (
      toset(flatten([for s in jsondecode(aws_iam_role_policy.loader[0].policy).Statement : s.Sid == "ReadLandingAndLake" ? tolist([s.Resource]) : []])) == toset(["arn:aws:s3:::hk-data-bucket/landing/*", "arn:aws:s3:::hk-data-bucket/lake/*"]) &&
      toset(flatten([for s in jsondecode(aws_iam_role_policy.loader[0].policy).Statement : s.Sid == "WriteLake" ? tolist([s.Resource]) : []])) == toset(["arn:aws:s3:::hk-data-bucket/lake/*"])
    )
    error_message = "Read landing/ and lake/, write lake/ only."
  }
  assert {
    condition = alltrue([for s in jsondecode(aws_iam_role_policy.loader[0].policy).Statement :
      alltrue([for a in flatten([s.Action]) : startswith(a, "s3:") || startswith(a, "kms:")])
    ])
    error_message = "The loader has S3 and KMS actions and nothing else: no Secrets Manager, SSM, ECR, IAM, STS."
  }
}

run "engine_host_may_assume_the_loader_and_nobody_else" {
  command = apply
  variables {
    loader_role_enabled = true
  }

  assert {
    condition = (
      length([for s in jsondecode(aws_iam_policy.host["engine"].policy).Statement : s if s.Sid == "AssumeTheLoaderRoleOnly" && s.Resource == ["arn:aws:iam::123456789012:role/hk-loader"] && s.Action == ["sts:AssumeRole"]]) == 1 &&
      !strcontains(aws_iam_policy.host["core"].policy, "sts:AssumeRole") &&
      !strcontains(aws_iam_policy.host["platform"].policy, "sts:AssumeRole")
    )
    error_message = "Only the engine host holds sts:AssumeRole, and only on the loader role."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.boundary.policy).Statement : s if s.Sid == "AllowAssumingTheLoaderRole" && s.Resource == ["arn:aws:iam::123456789012:role/hk-loader"]]) == 1
    error_message = "The boundary admits sts:AssumeRole on the loader role only (otherwise the identity allow is cut off)."
  }
}
