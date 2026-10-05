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

# Separate file: runs of one file share state.
# Automatic loader (docs/auto-loader.md).

run "loader_is_off_by_default_and_no_host_loads" {
  command = apply

  assert {
    condition     = length(output.loader_role_arns_effective) == 0
    error_message = "engine_host_can_load defaults to false and auto_loader_enabled to false: nobody loads."
  }
  assert {
    condition     = length(aws_ssm_parameter.engine_loader) == 0 && !contains(module.compute_engine.service_env_names, "loader") && length(module.compute_engine.extra_bundle_keys) == 0
    error_message = "Without auto_loader_enabled the engine host has no loader env, parameters or files."
  }
}

run "loader_needs_the_pipeline_image" {
  command = plan
  variables {
    auto_loader_enabled = true
  }
  expect_failures = [var.auto_loader_enabled]
}

run "loader_wires_role_bundle_parameters_and_a_bigger_engine_host" {
  command = apply
  variables {
    auto_loader_enabled = true
    images = {
      core = {
        core    = "r/pulso-prod/core-runtime@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        gateway = "r/pulso-prod/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      }
      platform = {
        support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
      }
      engine = {
        pulso    = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
        proxy    = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        pipeline = "r/pulso-prod/data-pipeline@sha256:3333333333333333333333333333333333333333333333333333333333333333"
      }
    }
  }

  assert {
    condition     = contains(output.loader_role_arns_effective, module.iam.loader_role_arn)
    error_message = "The dedicated loader role is a loader for the bucket policy (the PII Deny statements exempt it)."
  }
  assert {
    condition     = contains(module.compute_engine.service_env_names, "loader") && contains(module.compute_engine.extra_bundle_keys, "loader/pulso-loader.sh") && contains(module.compute_engine.extra_bundle_keys, "loader/check_cells_k.py") && contains(module.compute_engine.extra_bundle_keys, "loader/pulso-loader.timer")
    error_message = "The engine host renders loader.env and ships the loader files."
  }
  assert {
    condition     = alltrue([for k in ["LOADER_ROLE_ARN", "LOADER_EXTERNAL_ID", "LOADER_BUCKET", "LOADER_REGION", "LOADER_K_MIN", "LOADER_MEMORY", "LOADER_CPUS", "LOADER_DUCKDB_MEMORY"] : contains(keys(aws_ssm_parameter.engine_loader), k)])
    error_message = "Non-secret loader configuration is in SSM under /engine/loader/."
  }
  assert {
    condition     = aws_ssm_parameter.engine_loader["LOADER_K_MIN"].value == "10" && endswith(aws_ssm_parameter.engine_loader["LOADER_ROLE_ARN"].name, "/engine/loader/LOADER_ROLE_ARN")
    error_message = "k>=10 and the loader env names the script reads."
  }
  assert {
    condition     = output.profile_effective.instance_types["engine"] == "c7i-flex.large"
    error_message = "With the loader the engine host defaults to c7i-flex.large (4 GiB, Free Tier eligible); t3.small (2 GiB) cannot hold the build."
  }
  assert {
    condition     = !contains(keys(aws_ssm_parameter.engine_loader), "LOADER_CELLS_CMD")
    error_message = "No cells export unless loader_cells_cmd is set."
  }
}
