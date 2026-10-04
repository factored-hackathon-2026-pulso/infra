# Separate file: runs of one file share state, and the free_plan database volume is protected from destroy.
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

run "prod_profile_keeps_the_previous_design" {
  command = apply
  variables {
    profile = "prod"
  }

  assert {
    condition     = output.profile_effective.database_mode == "rds" && output.profile_effective.nat_gateway && output.profile_effective.edge_origin_mode == "vpc" && output.profile_effective.waf
    error_message = "prod = RDS, NAT gateway, CloudFront VPC origins, WAF on."
  }
  assert {
    condition     = output.profile_effective.instance_types["core"] == "t3.small" && output.profile_effective.image_builder_compute_type == "BUILD_GENERAL1_MEDIUM"
    error_message = "prod keeps t3.small hosts and MEDIUM CodeBuild."
  }
  assert {
    condition     = output.profile_effective.hosts_public_ip == false
    error_message = "prod hosts stay private."
  }
}
