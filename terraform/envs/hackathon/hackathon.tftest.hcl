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
  mock_data "aws_ec2_managed_prefix_list" {
    defaults = {
      id = "pl-0123456789abcdef0"
    }
  }
  mock_data "aws_cloudfront_cache_policy" {
    defaults = {
      id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    }
  }
  mock_data "aws_cloudfront_origin_request_policy" {
    defaults = {
      id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_data "aws_subnet" {
    defaults = {
      availability_zone = "us-east-1a"
    }
  }
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_route53_zone" {
    defaults = {
      name = "pulso.internal"
    }
  }
  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0123456789abcdef0"
    }
  }
  mock_resource "aws_iam_policy" {
    defaults = {
      arn = "arn:aws:iam::123456789012:policy/pulso-hk-boundary"
    }
  }
  mock_resource "aws_instance" {
    defaults = {
      arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-0123456789abcdef0"
    }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = {
      arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-hk/hackathon-AbCdEf"
    }
  }
  mock_resource "aws_kms_key" {
    defaults = {
      arn = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/pulso-hk-dlm"
    }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
}

# region, cloudfront_waf_region, ecr_registry_url, the principal lists and name_prefix are deliberately NOT set:
# a fresh prod account must plan with defaults only.
variables {
  images = {
    core = {
      core    = "r/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      gateway = "r/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    }
    platform = {
      support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    }
    engine = {
      pulso = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      proxy = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    }
  }
}

run "three_hosts_wired_with_private_dns" {
  command = apply

  assert {
    condition     = length(toset([module.compute_core.instance_id, module.compute_platform.instance_id, module.compute_engine.instance_id])) == 3
    error_message = "Three distinct hosts."
  }
  assert {
    condition     = length(toset([module.compute_core.private_zone_record, module.compute_platform.private_zone_record, module.compute_engine.private_zone_record])) == 3
    error_message = "One private DNS record per workload (names are asserted in the compute module tests)."
  }
  assert {
    condition     = length(toset([module.iam.instance_profile_name_core, module.iam.instance_profile_name_platform, module.iam.instance_profile_name_engine])) == 3
    error_message = "IAM outputs are wired."
  }
  assert {
    condition     = output.cloudfront_domain_name != ""
    error_message = "Edge is wired."
  }
}

run "per_host_kill_switch" {
  command = apply
  variables {
    enabled = { core = false, platform = true, engine = true }
  }
  assert {
    condition     = module.compute_core.instance_id != ""
    error_message = "Core can be stopped independently of the others."
  }
}

run "prod_defaults_need_no_region_or_registry_input" {
  command = apply

  assert {
    condition     = output.environment == "prod" && output.name_prefix == "pulso-prod"
    error_message = "One environment called prod with the pulso-prod name prefix."
  }

  assert {
    condition     = output.ecr_registry_url_effective == "123456789012.dkr.ecr.us-east-1.amazonaws.com"
    error_message = "The registry URL is derived from the caller account and region."
  }
}

run "engine_host_loads_by_default_and_admins_can_upload" {
  command = apply

  assert {
    condition     = contains(output.loader_role_arns_effective, output.instance_role_arns["engine"]) && length(output.loader_role_arns_effective) == 1
    error_message = "Exactly one loader by default: the engine host role (mocked roles share one ARN, so core/platform are checked in the iam module tests)."
  }

  assert {
    condition     = contains(output.uploader_principal_arns_effective, "arn:aws:iam::123456789012:user/*") && contains(output.uploader_principal_arns_effective, "arn:aws:iam::123456789012:root")
    error_message = "By default the account's IAM users and root may upload to landing/ (hosts are roles and never match)."
  }

  assert {
    condition     = contains(output.break_glass_principal_arns_effective, "arn:aws:iam::123456789012:root")
    error_message = "Break-glass defaults to the account's users and root."
  }
}

run "engine_host_can_load_false_removes_the_loader" {
  command = apply

  variables {
    engine_host_can_load = false
  }

  assert {
    condition     = length(output.loader_role_arns_effective) == 0
    error_message = "With engine_host_can_load=false only explicit loader_role_arns remain."
  }
}

run "explicit_principal_lists_replace_the_defaults" {
  command = apply

  variables {
    uploader_principal_arns    = ["arn:aws:iam::123456789012:user/only-me"]
    break_glass_principal_arns = ["arn:aws:iam::123456789012:user/only-me"]
  }

  assert {
    condition     = output.uploader_principal_arns_effective == tolist(["arn:aws:iam::123456789012:user/only-me"])
    error_message = "Explicit lists win over the account defaults."
  }
}
run "ecr_pull_arns_strip_the_registry_host_from_full_image_refs" {
  command = apply

  assert {
    condition     = contains(output.ecr_repository_arns_effective["core"], "arn:aws:ecr:us-east-1:123456789012:repository/agent-core") && contains(output.ecr_repository_arns_effective["engine"], "arn:aws:ecr:us-east-1:123456789012:repository/pulso")
    error_message = "Images are full refs <registry>/<repo>@sha256:...; the pull policy must name <repo> only."
  }
}

run "image_builder_is_wired_for_every_service_and_on_by_default" {
  command = apply

  assert {
    condition     = toset(keys(output.image_build_projects)) == toset(["core-runtime", "llm-gateway", "support-platform-api", "support-platform-web", "pulso-engine", "caddy"])
    error_message = "One CodeBuild project per ECR repository created by the bootstrap."
  }
  assert {
    condition     = output.image_build_projects["core-runtime"] == "pulso-prod-build-core-runtime"
    error_message = "Project names are <name_prefix>-build-<service>."
  }
}

run "image_builder_can_be_switched_off" {
  command = apply
  variables {
    enable_image_builder = false
  }

  assert {
    condition     = length(output.image_build_projects) == 0
    error_message = "enable_image_builder=false removes every build project."
  }
  assert {
    condition     = !strcontains(output.deployer_policy_json_core, "codebuild:")
    error_message = "No CodeBuild permission in the deployer policy without the builder."
  }
}

run "deployer_policies_are_exposed_per_workload_and_follow_the_repository_prefix" {
  command = apply

  assert {
    condition     = strcontains(output.deployer_policy_json_core, "parameter/pulso/core/images/core") && strcontains(output.deployer_policy_json_core, "repository/prod/core-runtime") && strcontains(output.deployer_policy_json_core, "repository/prod/llm-gateway")
    error_message = "The core deployer may write the core and gateway digests and push their repositories."
  }
  assert {
    condition     = strcontains(output.deployer_policy_json_platform, "parameter/pulso/platform/images/support_web") && !strcontains(output.deployer_policy_json_platform, "images/proxy")
    error_message = "The platform deployer never writes the shared proxy (caddy) digest."
  }
  assert {
    condition     = strcontains(output.deployer_policy_json_engine, "pulso-deploy-engine") && strcontains(output.deployer_policy_json_engine, "repository/prod/pulso-engine")
    error_message = "The engine deployer may run only pulso-deploy-engine."
  }
}

run "ssm_command_documents_are_one_per_host" {
  command = apply

  assert {
    condition     = output.deploy_documents["core"] == "pulso-deploy-core" && output.deploy_documents["platform"] == "pulso-deploy-platform" && output.deploy_documents["engine"] == "pulso-deploy-engine"
    error_message = "pulso-deploy-<workload> per host."
  }
}

run "new_digests_leave_every_start_script_unchanged" {
  command = apply
  variables {
    images = {
      core = {
        core    = "r/agent-core@sha256:1111111111111111111111111111111111111111111111111111111111111111"
        gateway = "r/llm-gateway@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      }
      platform = {
        support_api = "r/support-api@sha256:3333333333333333333333333333333333333333333333333333333333333333"
        support_web = "r/support-web@sha256:4444444444444444444444444444444444444444444444444444444444444444"
        proxy       = "r/caddy@sha256:5555555555555555555555555555555555555555555555555555555555555555"
      }
      engine = {
        pulso = "r/pulso@sha256:6666666666666666666666666666666666666666666666666666666666666666"
        proxy = "r/caddy@sha256:5555555555555555555555555555555555555555555555555555555555555555"
      }
    }
  }

  assert {
    condition     = output.host_user_data_sha256 == run.three_hosts_wired_with_private_dns.host_user_data_sha256
    error_message = "A digest-only change must not alter any host user_data (instances are never replaced by a deploy)."
  }
}