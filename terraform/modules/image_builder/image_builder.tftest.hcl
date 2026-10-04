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

variables {
  name         = "pulso-prod"
  region       = "us-east-1"
  bucket_name  = "pulso-prod-data-123456789012"
  kms_key_arn  = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  ecr_registry = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  tags         = { Environment = "prod" }
  services = {
    "core-runtime" = {
      repository       = "pulso-prod/core-runtime"
      dockerfile       = "core-bridge/Dockerfile"
      core_context_dir = "agent-core"
    }
    "support-platform-api" = {
      repository  = "pulso-prod/support-platform-api"
      dockerfile  = "api/Dockerfile"
      context_dir = "api"
    }
    "caddy" = {
      repository = "pulso-prod/caddy"
      mode       = "mirror"
    }
  }
}

run "disabled_by_default_creates_nothing" {
  command = plan

  assert {
    condition     = length(aws_codebuild_project.this) == 0 && length(aws_iam_role.build) == 0 && length(aws_cloudwatch_log_group.build) == 0
    error_message = "enabled defaults to false: no project, role or log group."
  }
  assert {
    condition     = length(output.project_names) == 0
    error_message = "No project names when disabled."
  }
}

run "enabled_one_privileged_x86_project_per_service" {
  command = plan
  variables {
    enabled = true
  }

  assert {
    condition     = toset(keys(aws_codebuild_project.this)) == toset(["caddy", "core-runtime", "support-platform-api"])
    error_message = "One project per service."
  }
  assert {
    condition     = alltrue([for k, p in aws_codebuild_project.this : one(p.environment).privileged_mode == true && one(p.environment).type == "LINUX_CONTAINER"])
    error_message = "Docker builds need privileged mode on a Linux x86_64 container."
  }
  assert {
    condition     = alltrue([for k, p in aws_codebuild_project.this : one(p.environment).compute_type == "BUILD_GENERAL1_MEDIUM" && p.build_timeout == 60])
    error_message = "Defaults: BUILD_GENERAL1_MEDIUM and a 60 minute timeout."
  }
  assert {
    condition     = alltrue([for k, p in aws_codebuild_project.this : length(p.vpc_config) == 0])
    error_message = "Default CodeBuild network: no VPC attachment, no path to the private subnets."
  }
  assert {
    condition     = alltrue([for k, p in aws_codebuild_project.this : alltrue([for v in one(p.environment).environment_variable : v.type == "PLAINTEXT"])])
    error_message = "No secrets: every build variable is plain configuration, never PARAMETER_STORE or SECRETS_MANAGER."
  }
  assert {
    condition     = output.project_names["core-runtime"] == "pulso-prod-build-core-runtime"
    error_message = "Project names are <name>-build-<service>."
  }
}

run "compute_type_and_timeout_are_variables" {
  command = plan
  variables {
    enabled      = true
    compute_type = "BUILD_GENERAL1_LARGE"
    timeout_mins = 30
  }

  assert {
    condition     = alltrue([for k, p in aws_codebuild_project.this : one(p.environment).compute_type == "BUILD_GENERAL1_LARGE" && p.build_timeout == 30])
    error_message = "compute_type and timeout_mins are honoured."
  }
}

run "sources_are_s3_zips_except_mirror" {
  command = plan
  variables {
    enabled = true
  }

  assert {
    condition     = one(aws_codebuild_project.this["core-runtime"].source).type == "S3" && startswith(one(aws_codebuild_project.this["core-runtime"].source).location, "pulso-prod-data-123456789012/engine/build-src/core-runtime/")
    error_message = "Build sources are zips under engine/build-src/<service>/ in the single bucket."
  }
  assert {
    condition     = one(aws_codebuild_project.this["caddy"].source).type == "NO_SOURCE"
    error_message = "Mirroring a third-party image needs no source."
  }
}

run "service_variables_carry_the_dockerfile_and_core_context" {
  command = plan
  variables {
    enabled = true
  }

  assert {
    condition     = one([for v in one(aws_codebuild_project.this["core-runtime"].environment).environment_variable : v.value if v.name == "DOCKERFILE"]) == "core-bridge/Dockerfile"
    error_message = "DOCKERFILE comes from the service definition."
  }
  assert {
    condition     = one([for v in one(aws_codebuild_project.this["core-runtime"].environment).environment_variable : v.value if v.name == "CORE_CONTEXT_DIR"]) == "agent-core"
    error_message = "The agent-core checkout inside the zip becomes --build-context core=<dir>."
  }
  assert {
    condition     = one([for v in one(aws_codebuild_project.this["support-platform-api"].environment).environment_variable : v.value if v.name == "CORE_CONTEXT_DIR"]) == ""
    error_message = "No extra build context for other services."
  }
  assert {
    condition     = one([for v in one(aws_codebuild_project.this["caddy"].environment).environment_variable : v.value if v.name == "BUILD_MODE"]) == "mirror"
    error_message = "Mirror mode is explicit."
  }
  assert {
    condition     = one([for v in one(aws_codebuild_project.this["caddy"].environment).environment_variable : v.value if v.name == "ECR_REPOSITORY"]) == "pulso-prod/caddy"
    error_message = "The target repository is fixed per project."
  }
}

run "buildspec_logs_in_builds_and_records_the_digest" {
  command = plan
  variables {
    enabled = true
  }

  assert {
    condition     = strcontains(one(aws_codebuild_project.this["core-runtime"].source).buildspec, "docker login") && strcontains(one(aws_codebuild_project.this["core-runtime"].source).buildspec, "--build-context core=")
    error_message = "Buildspec logs in to ECR and supports --build-context core=<dir>."
  }
  assert {
    condition     = strcontains(one(aws_codebuild_project.this["core-runtime"].source).buildspec, "describe-images") && strcontains(one(aws_codebuild_project.this["core-runtime"].source).buildspec, "OUTPUT_PREFIX")
    error_message = "The pushed digest is read back from ECR and written to build-out/<service>/<id>.json."
  }
  assert {
    condition     = !strcontains(one(aws_codebuild_project.this["core-runtime"].source).buildspec, "latest")
    error_message = "Never pushes a latest tag."
  }
  assert {
    condition     = strcontains(one(aws_codebuild_project.this["caddy"].source).buildspec, "docker pull") && strcontains(one(aws_codebuild_project.this["caddy"].source).buildspec, "MIRROR_IMAGE")
    error_message = "Mirror projects pull the third-party image."
  }
}

run "role_is_least_privilege_per_service" {
  command = plan
  variables {
    enabled = true
  }

  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement :
      !contains(flatten([s.Action]), "iam:*") && !contains(flatten([s.Action]), "*") && !contains(flatten([s.Action]), "s3:*") && !contains(flatten([s.Action]), "ecr:*")
    ])
    error_message = "No wildcard actions."
  }
  assert {
    condition = alltrue([
      for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement :
      s.Resource == "*" ? s.Sid == "EcrToken" : true
    ])
    error_message = "Only ecr:GetAuthorizationToken (which has no resource scoping) uses Resource *."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement : s if s.Sid == "EcrPush"]).Resource == "arn:aws:ecr:us-east-1:123456789012:repository/pulso-prod/core-runtime"
    error_message = "ECR push only to the service's own repository."
  }
  assert {
    condition     = !contains(one([for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement : s if s.Sid == "EcrPush"]).Action, "ecr:BatchDeleteImage")
    error_message = "The builder never deletes images."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement : s if s.Sid == "ReadSource"]).Resource == "arn:aws:s3:::pulso-prod-data-123456789012/engine/build-src/core-runtime/*"
    error_message = "Read only its own build-src/<service>/ prefix."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement : s if s.Sid == "WriteBuildOutput"]).Resource == "arn:aws:s3:::pulso-prod-data-123456789012/engine/build-out/core-runtime/*" && one([for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement : s if s.Sid == "WriteBuildOutput"]).Action == "s3:PutObject"
    error_message = "Write only its own build-out/<service>/ prefix."
  }
  assert {
    condition     = one([for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement : s if s.Sid == "UseDataKey"]).Resource == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "KMS decrypt and encrypt on the bucket key only."
  }
  assert {
    condition     = length([for s in jsondecode(aws_iam_role_policy.build["core-runtime"].policy).Statement : s if strcontains(jsonencode(s.Resource), "support-platform-api")]) == 0
    error_message = "A service role never touches another service's repository or prefixes."
  }
}

run "role_trusts_only_codebuild" {
  command = plan
  variables {
    enabled = true
  }

  assert {
    condition     = jsondecode(aws_iam_role.build["caddy"].assume_role_policy).Statement[0].Principal.Service == "codebuild.amazonaws.com"
    error_message = "Only CodeBuild assumes the build roles."
  }
}

run "logs_are_kept_for_a_bounded_time" {
  command = plan
  variables {
    enabled = true
  }

  assert {
    condition     = alltrue([for k, g in aws_cloudwatch_log_group.build : g.retention_in_days == 30])
    error_message = "Build logs expire after 30 days by default."
  }
}

run "rejects_unsafe_service_names" {
  command = plan
  variables {
    services = {
      "../x" = { repository = "pulso-prod/x" }
    }
  }
  expect_failures = [var.services]
}

run "rejects_unknown_mode" {
  command = plan
  variables {
    services = {
      x = { repository = "pulso-prod/x", mode = "push-anything" }
    }
  }
  expect_failures = [var.services]
}
run "build_args_are_passed_to_docker_build" {
  command = plan
  variables {
    enabled = true
  }

  assert {
    condition     = one([for v in one(aws_codebuild_project.this["support-platform-api"].environment).environment_variable : v.value if v.name == "BUILD_ARGS"]) == ""
    error_message = "BUILD_ARGS (space separated KEY=VALUE, set per build, for example VITE_API_URL) defaults to empty."
  }
  assert {
    condition     = strcontains(one(aws_codebuild_project.this["support-platform-api"].source).buildspec, "--build-arg")
    error_message = "The buildspec forwards BUILD_ARGS as --build-arg."
  }
}
