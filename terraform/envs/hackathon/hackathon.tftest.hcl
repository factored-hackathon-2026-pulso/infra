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
  mock_data "aws_route53_zone" {
    defaults = {
      name = "pulso.internal"
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
    condition     = module.compute_core.private_zone_record == "core.pulso.internal" && module.compute_engine.private_zone_record == "engine.pulso.internal"
    error_message = "Private DNS names per workload."
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
