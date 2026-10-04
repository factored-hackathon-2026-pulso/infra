mock_provider "aws" {
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
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/pulso-hk-dlm"
    }
  }
}

variables {
  ecr_registry_url = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  images = {
    core_runtime = "r/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    llm_gateway  = "r/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    support_api  = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    support_web  = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    pulso        = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    proxy        = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  }
}

run "composition_wires_compute_and_edge" {
  command = apply

  assert {
    condition     = module.compute.instance_id != "" && output.cloudfront_domain_name != ""
    error_message = "Composition must wire compute and edge."
  }
}
