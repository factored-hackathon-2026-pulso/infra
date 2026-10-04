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
}

override_resource {
  target          = aws_iam_policy.boundary
  override_during = plan
  values = {
    arn = "arn:aws:iam::123456789012:policy/hk-boundary"
  }
}

variables {
  name                         = "hk"
  region                       = "us-east-1"
  ssm_parameter_path_prefix    = "/hk"
  s3_bucket_name               = "hk-data-bucket"
  core_s3_prefixes             = ["core/blobs"]
  engine_s3_prefixes           = ["engine"]
  engine_lake_read_prefixes    = ["landing", "lake"]
  ecr_repository_arns_core     = ["arn:aws:ecr:us-east-1:123456789012:repository/hk/core"]
  ecr_repository_arns_platform = ["arn:aws:ecr:us-east-1:123456789012:repository/hk/platform"]
  ecr_repository_arns_engine   = ["arn:aws:ecr:us-east-1:123456789012:repository/hk/engine"]
  secret_arn                   = "arn:aws:secretsmanager:us-east-1:123456789012:secret:hk/hackathon-AbCdEf"
  kms_key_arn                  = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  tags                         = { Environment = "hackathon" }
}

run "three_roles_assumable_by_ec2_only_and_bounded" {
  command = plan

  assert {
    condition     = toset(keys(aws_iam_role.host)) == toset(["core", "platform", "engine"])
    error_message = "One role per workload."
  }

  assert {
    condition     = alltrue([for r in aws_iam_role.host : jsondecode(r.assume_role_policy).Statement[0].Principal.Service == "ec2.amazonaws.com" && r.permissions_boundary == aws_iam_policy.boundary.arn])
    error_message = "Only EC2 assumes the roles, and each carries the deny-list boundary."
  }

  assert {
    condition     = toset(keys(aws_iam_instance_profile.host)) == toset(["core", "platform", "engine"])
    error_message = "One instance profile per workload."
  }
}

run "ssm_core_attached_to_each" {
  command = plan

  assert {
    condition     = length(aws_iam_role_policy_attachment.ssm_core) == 3 && alltrue([for a in aws_iam_role_policy_attachment.ssm_core : a.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"])
    error_message = "Session Manager access on all hosts."
  }
}

run "each_workload_reads_only_its_own_parameter_path" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_policy.host["core"].policy).Statement[index([for s in jsondecode(aws_iam_policy.host["core"].policy).Statement : s.Sid], "ReadParameters")].Resource == "arn:aws:ssm:us-east-1:123456789012:parameter/hk/core/*"
    error_message = "Core reads /hk/core only."
  }

  assert {
    condition     = jsondecode(aws_iam_policy.host["engine"].policy).Statement[index([for s in jsondecode(aws_iam_policy.host["engine"].policy).Statement : s.Sid], "ReadParameters")].Resource == "arn:aws:ssm:us-east-1:123456789012:parameter/hk/engine/*"
    error_message = "Engine reads /hk/engine only."
  }

  assert {
    condition     = jsondecode(aws_iam_policy.host["platform"].policy).Statement[index([for s in jsondecode(aws_iam_policy.host["platform"].policy).Statement : s.Sid], "ReadParameters")].Resource == "arn:aws:ssm:us-east-1:123456789012:parameter/hk/platform/*"
    error_message = "Platform reads /hk/platform only."
  }
}

run "s3_scoped_per_workload" {
  command = plan

  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_policy.host["core"].policy).Statement : s.Sid == "ObjectReadWrite" ? tolist([s.Resource]) : []])) == toset(["arn:aws:s3:::hk-data-bucket/core/blobs/*"])
    error_message = "Core writes only core/blobs."
  }

  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_policy.host["engine"].policy).Statement : s.Sid == "ObjectReadWrite" ? tolist([s.Resource]) : []])) == toset(["arn:aws:s3:::hk-data-bucket/engine/*"])
    error_message = "Engine writes only engine/."
  }

  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_policy.host["engine"].policy).Statement : s.Sid == "ObjectReadOnly" ? tolist([s.Resource]) : []])) == toset(["arn:aws:s3:::hk-data-bucket/landing/*", "arn:aws:s3:::hk-data-bucket/lake/*"])
    error_message = "Engine reads landing and lake through the loader prefixes."
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.host["platform"].policy).Statement : s if startswith(tolist(flatten([s.Action]))[0], "s3:") && !contains(["ListBundle", "ReadBundle"], s.Sid)]) == 0
    error_message = "Platform has no S3 access beyond its deploy bundle."
  }
}

run "only_ecr_token_uses_wildcard_resource_and_no_wildcard_actions" {
  command = plan

  assert {
    condition     = alltrue([for w in ["core", "platform", "engine"] : length([for s in jsondecode(aws_iam_policy.host[w].policy).Statement : s.Sid if contains(tolist(flatten([s.Resource])), "*")]) == 1])
    error_message = "Exactly one Resource * statement per policy: ecr:GetAuthorizationToken."
  }

  assert {
    condition     = alltrue([for w in ["core", "platform", "engine"] : length([for s in jsondecode(aws_iam_policy.host[w].policy).Statement : s if s.Effect == "Allow" && length([for a in flatten([s.Action]) : a if endswith(a, "*")]) > 0]) == 0])
    error_message = "No wildcard actions."
  }
}

run "ecr_pull_scoped_per_workload" {
  command = plan

  assert {
    condition     = toset(flatten([jsondecode(aws_iam_policy.host["core"].policy).Statement[index([for s in jsondecode(aws_iam_policy.host["core"].policy).Statement : s.Sid], "EcrPull")].Resource])) == toset(["arn:aws:ecr:us-east-1:123456789012:repository/hk/core"])
    error_message = "Each host pulls only its own repositories."
  }
}

run "logs_write_scoped_to_prefix" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_policy.host["engine"].policy).Statement[index([for s in jsondecode(aws_iam_policy.host["engine"].policy).Statement : s.Sid], "WriteLogs")].Resource == "arn:aws:logs:us-east-1:123456789012:log-group:/hk/*:*"
    error_message = "Log writes limited to the name-prefixed log groups."
  }
}

run "boundary_denies_iam_and_organizations" {
  command = plan

  assert {
    condition     = contains(flatten([for s in jsondecode(aws_iam_policy.boundary.policy).Statement : s.Effect == "Deny" ? tolist([s.Action]) : []]), "iam:*") || contains(flatten([for s in jsondecode(aws_iam_policy.boundary.policy).Statement : s.Effect == "Deny" ? [s.Action] : []]), "iam:*")
    error_message = "The boundary denies IAM changes."
  }

  assert {
    condition     = contains(flatten([for s in jsondecode(aws_iam_policy.boundary.policy).Statement : s.Effect == "Deny" ? [s.Action] : []]), "organizations:*")
    error_message = "The boundary denies Organizations changes."
  }
}

run "each_host_reads_exactly_the_one_secret_and_decrypts_with_the_data_key" {
  command = plan

  assert {
    condition     = alltrue([for w in ["core", "platform", "engine"] : jsondecode(aws_iam_policy.host[w].policy).Statement[index([for s in jsondecode(aws_iam_policy.host[w].policy).Statement : s.Sid], "ReadSecret")].Resource == "arn:aws:secretsmanager:us-east-1:123456789012:secret:hk/hackathon-AbCdEf"])
    error_message = "Each host reads the one secret ARN and nothing else."
  }

  assert {
    condition     = alltrue([for w in ["core", "platform", "engine"] : toset(flatten([jsondecode(aws_iam_policy.host[w].policy).Statement[index([for s in jsondecode(aws_iam_policy.host[w].policy).Statement : s.Sid], "ReadSecret")].Action])) == toset(["secretsmanager:GetSecretValue"])])
    error_message = "Only GetSecretValue on the secret."
  }

  assert {
    condition     = alltrue([for w in ["core", "platform", "engine"] : jsondecode(aws_iam_policy.host[w].policy).Statement[index([for s in jsondecode(aws_iam_policy.host[w].policy).Statement : s.Sid], "UseDataKey")].Resource == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"])
    error_message = "kms:Decrypt on the data key only."
  }
}

run "each_host_reads_its_deploy_bundle" {
  command = plan

  assert {
    condition     = alltrue([for w in ["core", "platform", "engine"] : jsondecode(aws_iam_policy.host[w].policy).Statement[index([for s in jsondecode(aws_iam_policy.host[w].policy).Statement : s.Sid], "ReadBundle")].Resource == "arn:aws:s3:::hk-data-bucket/engine/deploy/${w}/*"])
    error_message = "Each host reads engine/deploy/<workload>/* so pulso-stack-prepare can sync it."
  }

  assert {
    condition     = alltrue([for w in ["core", "platform", "engine"] : jsondecode(aws_iam_policy.host[w].policy).Statement[index([for s in jsondecode(aws_iam_policy.host[w].policy).Statement : s.Sid], "ListBundle")].Condition.StringLike["s3:prefix"] == ["engine/deploy/${w}/*"]])
    error_message = "ListBucket only under the bundle prefix."
  }
}

run "cloudwatch_agent_may_create_its_log_group" {
  command = plan

  assert {
    condition     = jsondecode(aws_iam_policy.host["core"].policy).Statement[index([for s in jsondecode(aws_iam_policy.host["core"].policy).Statement : s.Sid], "CreateLogGroup")].Resource == "arn:aws:logs:us-east-1:123456789012:log-group:/hk/*"
    error_message = "CreateLogGroup scoped to the name prefix."
  }
}
run "boundary_allow_is_not_a_star_action" {
  command = plan

  assert {
    condition     = alltrue([for s in jsondecode(aws_iam_policy.boundary.policy).Statement : s.Effect == "Deny" || !contains(flatten([s.Action]), "*")])
    error_message = "The boundary's Allow lists service families, never the star action."
  }
}
run "engine_can_load_adds_loader_access_to_the_engine_role_only" {
  command = plan

  variables {
    engine_can_load           = true
    engine_lake_read_prefixes = ["lake/gold_masked", "lake/gold_analytics"]
  }

  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_policy.host["engine"].policy).Statement : s.Sid == "ObjectReadOnly" ? tolist([s.Resource]) : []])) == toset(["arn:aws:s3:::hk-data-bucket/landing/*", "arn:aws:s3:::hk-data-bucket/lake/*"])
    error_message = "With engine_can_load the engine reads landing/ and lake/."
  }

  assert {
    condition     = toset(flatten([for s in jsondecode(aws_iam_policy.host["engine"].policy).Statement : s.Sid == "LoaderWriteLake" ? tolist([s.Resource]) : []])) == toset(["arn:aws:s3:::hk-data-bucket/lake/*"])
    error_message = "The engine loader writes lake/ only."
  }

  assert {
    condition     = alltrue([for w in ["core", "platform"] : !strcontains(aws_iam_policy.host[w].policy, "/landing/")])
    error_message = "Core and platform never get landing/ or bronze access."
  }
}

run "engine_cannot_load_by_default" {
  command = plan

  variables {
    engine_lake_read_prefixes = ["lake/gold_masked", "lake/gold_analytics"]
  }

  assert {
    condition     = length([for s in jsondecode(aws_iam_policy.host["engine"].policy).Statement : s if s.Sid == "LoaderWriteLake"]) == 0 && !strcontains(aws_iam_policy.host["engine"].policy, "/landing/")
    error_message = "Without engine_can_load the engine has no landing/ access and cannot write lake/."
  }
}
