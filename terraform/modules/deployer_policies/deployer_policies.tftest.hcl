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
  region      = "us-east-1"
  ssm_prefix  = "/pulso"
  bucket_name = "pulso-prod-data-123456789012"
  kms_key_arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  workloads = {
    core = {
      image_keys     = ["core", "gateway"]
      repositories   = ["pulso-prod/core-runtime", "pulso-prod/llm-gateway"]
      build_services = ["core-runtime", "llm-gateway"]
    }
    platform = {
      image_keys     = ["support_api", "support_web"]
      repositories   = ["pulso-prod/support-platform-api", "pulso-prod/support-platform-web"]
      build_services = ["support-platform-api", "support-platform-web"]
    }
    engine = {
      image_keys     = ["pulso"]
      repositories   = ["pulso-prod/pulso-engine"]
      build_services = ["pulso-engine"]
    }
  }
  project_arns = {
    "core-runtime"         = "arn:aws:codebuild:us-east-1:123456789012:project/pulso-prod-build-core-runtime"
    "llm-gateway"          = "arn:aws:codebuild:us-east-1:123456789012:project/pulso-prod-build-llm-gateway"
    "support-platform-api" = "arn:aws:codebuild:us-east-1:123456789012:project/pulso-prod-build-support-platform-api"
    "support-platform-web" = "arn:aws:codebuild:us-east-1:123456789012:project/pulso-prod-build-support-platform-web"
    "pulso-engine"         = "arn:aws:codebuild:us-east-1:123456789012:project/pulso-prod-build-pulso-engine"
  }
}

run "three_valid_policy_documents" {
  command = plan

  assert {
    condition     = alltrue([for j in [output.deployer_policy_json_core, output.deployer_policy_json_platform, output.deployer_policy_json_engine] : can(jsondecode(j).Statement)])
    error_message = "Each output is an IAM policy document."
  }
  assert {
    condition     = jsondecode(output.deployer_policy_json_platform).Version == "2012-10-17"
    error_message = "Policy language version."
  }
}

run "no_wildcard_actions_and_resource_star_only_where_aws_requires_it" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for j in [output.deployer_policy_json_core, output.deployer_policy_json_platform, output.deployer_policy_json_engine] : [
        for s in jsondecode(j).Statement :
        alltrue([for a in flatten([s.Action]) : !endswith(a, "*") && a != "*"])
      ]
    ]))
    error_message = "No wildcard actions."
  }
  assert {
    condition = alltrue(flatten([
      for j in [output.deployer_policy_json_core, output.deployer_policy_json_platform, output.deployer_policy_json_engine] : [
        for s in jsondecode(j).Statement :
        s.Resource == "*" ? contains(["EcrToken", "ReadCommandResult"], s.Sid) : true
      ]
    ]))
    error_message = "Resource * only for ecr:GetAuthorizationToken and ssm:GetCommandInvocation, which AWS cannot scope."
  }
  assert {
    condition = alltrue(flatten([
      for j in [output.deployer_policy_json_core, output.deployer_policy_json_platform, output.deployer_policy_json_engine] : [
        for s in jsondecode(j).Statement :
        !strcontains(join(",", flatten([s.Action])), "iam:") && !strcontains(join(",", flatten([s.Action])), "ec2:") && !strcontains(join(",", flatten([s.Action])), "secretsmanager:")
      ]
    ]))
    error_message = "A deployer never touches IAM, EC2 or secrets."
  }
}

run "ssm_put_only_on_the_workloads_service_image_parameters" {
  command = plan

  assert {
    condition = toset(flatten([one([for s in jsondecode(output.deployer_policy_json_platform).Statement : s if s.Sid == "WriteImageParameters"]).Resource])) == toset([
      "arn:aws:ssm:us-east-1:123456789012:parameter/pulso/platform/images/support_api",
      "arn:aws:ssm:us-east-1:123456789012:parameter/pulso/platform/images/support_web",
    ])
    error_message = "ssm:PutParameter only on that workload's service image parameters (never proxy, never config)."
  }
  assert {
    condition     = one([for s in jsondecode(output.deployer_policy_json_platform).Statement : s if s.Sid == "WriteImageParameters"]).Action == "ssm:PutParameter"
    error_message = "Only PutParameter."
  }
  assert {
    condition     = !strcontains(output.deployer_policy_json_core, "/platform/") && !strcontains(output.deployer_policy_json_engine, "/platform/")
    error_message = "Core and engine deployers never see the platform parameters."
  }
  assert {
    condition     = strcontains(output.deployer_policy_json_platform, "ssm:GetParameterHistory")
    error_message = "Rollback reads the previous digest from the parameter history."
  }
}

run "send_command_only_for_the_workload_document_and_tagged_instance" {
  command = plan

  assert {
    condition     = one([for s in jsondecode(output.deployer_policy_json_core).Statement : s if s.Sid == "SendDeployDocument"]).Resource == "arn:aws:ssm:us-east-1:123456789012:document/pulso-deploy-core"
    error_message = "Only the pulso-deploy-<workload> document."
  }
  assert {
    condition     = one([for s in jsondecode(output.deployer_policy_json_core).Statement : s if s.Sid == "SendDeployInstance"]).Condition.StringEquals["ssm:resourceTag/Workload"] == "core"
    error_message = "Only instances tagged with the workload."
  }
  assert {
    condition     = !strcontains(output.deployer_policy_json_core, "AWS-RunShellScript")
    error_message = "No arbitrary shell document."
  }
}

run "s3_build_prefixes_are_per_service" {
  command = plan

  assert {
    condition = toset(flatten([one([for s in jsondecode(output.deployer_policy_json_platform).Statement : s if s.Sid == "PutBuildSource"]).Resource])) == toset([
      "arn:aws:s3:::pulso-prod-data-123456789012/engine/build-src/support-platform-api/*",
      "arn:aws:s3:::pulso-prod-data-123456789012/engine/build-src/support-platform-web/*",
    ])
    error_message = "s3:PutObject only on build-src/<service>/ of the workload's services."
  }
  assert {
    condition = toset(flatten([one([for s in jsondecode(output.deployer_policy_json_platform).Statement : s if s.Sid == "GetBuildOutput"]).Resource])) == toset([
      "arn:aws:s3:::pulso-prod-data-123456789012/engine/build-out/support-platform-api/*",
      "arn:aws:s3:::pulso-prod-data-123456789012/engine/build-out/support-platform-web/*",
    ])
    error_message = "s3:GetObject only on build-out/<service>/."
  }
  assert {
    condition     = one([for s in jsondecode(output.deployer_policy_json_platform).Statement : s if s.Sid == "UseDataKey"]).Resource == "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    error_message = "KMS on the bucket key only."
  }
}

run "ecr_and_codebuild_are_scoped_to_the_workloads_services" {
  command = plan

  assert {
    condition     = toset(flatten([one([for s in jsondecode(output.deployer_policy_json_engine).Statement : s if s.Sid == "EcrPushPull"]).Resource])) == toset(["arn:aws:ecr:us-east-1:123456789012:repository/pulso-prod/pulso-engine"])
    error_message = "ECR only on the workload's repositories."
  }
  assert {
    condition     = !contains(flatten([one([for s in jsondecode(output.deployer_policy_json_engine).Statement : s if s.Sid == "EcrPushPull"]).Action]), "ecr:BatchDeleteImage")
    error_message = "A deployer cannot delete images."
  }
  assert {
    condition     = toset(flatten([one([for s in jsondecode(output.deployer_policy_json_core).Statement : s if s.Sid == "Build"]).Resource])) == toset([var.project_arns["core-runtime"], var.project_arns["llm-gateway"]])
    error_message = "codebuild:StartBuild and BatchGetBuilds only on the workload's projects."
  }
  assert {
    condition     = !strcontains(output.deployer_policy_json_core, "support-platform") && !strcontains(output.deployer_policy_json_core, "pulso-engine")
    error_message = "No cross-workload access."
  }
}

run "no_build_statement_when_the_builder_is_off" {
  command = plan
  variables {
    project_arns = {}
  }

  assert {
    condition     = length([for s in jsondecode(output.deployer_policy_json_core).Statement : s if s.Sid == "Build"]) == 0
    error_message = "No CodeBuild statement without projects."
  }
}
run "command_results_can_be_listed_and_read" {
  command = plan

  assert {
    condition     = toset(flatten([one([for s in jsondecode(output.deployer_policy_json_core).Statement : s if s.Sid == "ReadCommandResult"]).Action])) == toset(["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"])
    error_message = "A deployer that targets by tag finds the instance with ListCommandInvocations, then reads its output."
  }
}
run "build_logs_are_readable_for_the_workloads_projects_only" {
  command = plan

  assert {
    condition = toset(flatten([one([for s in jsondecode(output.deployer_policy_json_engine).Statement : s if s.Sid == "ReadBuildLogs"]).Resource])) == toset([
      "arn:aws:logs:us-east-1:123456789012:log-group:/aws/codebuild/pulso-prod-build-pulso-engine:*",
    ])
    error_message = "A failed build is debugged from its own CodeBuild log group, nothing else."
  }
  assert {
    condition     = toset(flatten([one([for s in jsondecode(output.deployer_policy_json_engine).Statement : s if s.Sid == "ReadBuildLogs"]).Action])) == toset(["logs:GetLogEvents", "logs:FilterLogEvents", "logs:DescribeLogStreams"])
    error_message = "Read-only log actions."
  }
}
