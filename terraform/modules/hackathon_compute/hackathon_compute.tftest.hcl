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
  name_prefix           = "pulso-hk"
  region                = "us-east-1"
  workload              = "core"
  subnet_id             = "subnet-0123456789abcdef0"
  security_group_ids    = ["sg-0123456789abcdef0"]
  instance_profile_name = "pulso-hk-core"
  private_zone_id       = "Z0123456789ABCDEFGHIJ"
  ssm_prefix            = "/pulso-hk"
  bucket_name           = "pulso-hk-data"
  secret_arn            = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-hk-abc123"
  kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  ecr_registry_url      = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  images = {
    core         = "r/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    gateway      = "r/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    support_api  = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    support_web  = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    pulso        = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    proxy        = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  }
}

run "bundle_rules_core" {
  command = apply
  variables {
    workload = "core"
  }

  assert {
    condition     = !can(regex(":latest", local.compose_text))
    error_message = "No :latest tags."
  }
  assert {
    condition = alltrue([for n, s in local.compose.services :
      (contains(keys(s), "ports") ? contains(local.allowed_ports, one(s.ports)) : true)
    ])
    error_message = "Only the allowed port is published (proxies 80; core-runtime 8000 on core)."
  }
  assert {
    condition     = !contains(keys(try(local.compose.services["llm-gateway"], {}), "ports")
    error_message = "The gateway is never published."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : can(regex("^[0-9]+m$", s.mem_limit)) && contains(keys(s), "restart")])
    error_message = "Every service has a memory limit and a restart policy."
  }
  assert {
    condition     = sum([for n, s in local.compose.services : tonumber(trimsuffix(s.mem_limit, "m"))]) <= local.instance_memory_mb * 0.7
    error_message = "Memory limits must leave 30 percent headroom on the host."
  }
  assert {
    condition     = contains(local.service_env_names, "common") && length(local.service_env_names) == 3
    error_message = "Each host gets only its own secret slice."
  }
  assert {
    condition     = aws_route53_record.this.name == "core.pulso.internal" && aws_route53_record.this.type == "A"
    error_message = "Private DNS record per workload."
  }
}

run "bundle_rules_platform" {
  command = apply
  variables {
    workload = "platform"
  }

  assert {
    condition     = !can(regex(":latest", local.compose_text))
    error_message = "No :latest tags."
  }
  assert {
    condition = alltrue([for n, s in local.compose.services :
      (contains(keys(s), "ports") ? contains(local.allowed_ports, one(s.ports)) : true)
    ])
    error_message = "Only the allowed port is published (proxies 80; core-runtime 8000 on core)."
  }
  assert {
    condition     = !contains(keys(try(local.compose.services["llm-gateway"], {}), "ports")
    error_message = "The gateway is never published."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : can(regex("^[0-9]+m$", s.mem_limit)) && contains(keys(s), "restart")])
    error_message = "Every service has a memory limit and a restart policy."
  }
  assert {
    condition     = sum([for n, s in local.compose.services : tonumber(trimsuffix(s.mem_limit, "m"))]) <= local.instance_memory_mb * 0.7
    error_message = "Memory limits must leave 30 percent headroom on the host."
  }
  assert {
    condition     = contains(local.service_env_names, "common") && length(local.service_env_names) == 2
    error_message = "Each host gets only its own secret slice."
  }
  assert {
    condition     = aws_route53_record.this.name == "platform.pulso.internal" && aws_route53_record.this.type == "A"
    error_message = "Private DNS record per workload."
  }
}

run "bundle_rules_engine" {
  command = apply
  variables {
    workload = "engine"
  }

  assert {
    condition     = !can(regex(":latest", local.compose_text))
    error_message = "No :latest tags."
  }
  assert {
    condition = alltrue([for n, s in local.compose.services :
      (contains(keys(s), "ports") ? contains(local.allowed_ports, one(s.ports)) : true)
    ])
    error_message = "Only the allowed port is published (proxies 80; core-runtime 8000 on core)."
  }
  assert {
    condition     = !contains(keys(try(local.compose.services["llm-gateway"], {}), "ports")
    error_message = "The gateway is never published."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : can(regex("^[0-9]+m$", s.mem_limit)) && contains(keys(s), "restart")])
    error_message = "Every service has a memory limit and a restart policy."
  }
  assert {
    condition     = sum([for n, s in local.compose.services : tonumber(trimsuffix(s.mem_limit, "m"))]) <= local.instance_memory_mb * 0.7
    error_message = "Memory limits must leave 30 percent headroom on the host."
  }
  assert {
    condition     = contains(local.service_env_names, "common") && length(local.service_env_names) == 2
    error_message = "Each host gets only its own secret slice."
  }
  assert {
    condition     = aws_route53_record.this.name == "engine.pulso.internal" && aws_route53_record.this.type == "A"
    error_message = "Private DNS record per workload."
  }
}

run "defaults_are_hardened" {
  command = apply

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.associate_public_ip_address == false
    error_message = "Root volume encrypted, host private."
  }
  assert {
    condition     = aws_instance.this.instance_type == "t3.small"
    error_message = "Default instance type is t3.small."
  }
}

run "data_volume_sizes_per_workload" {
  command = apply
  variables {
    data_volume_size_gb = 40
  }
  assert {
    condition     = aws_ebs_volume.data_protected[0].encrypted && aws_ebs_volume.data_protected[0].type == "gp3" && aws_ebs_volume.data_protected[0].size == 40
    error_message = "Data volume honors the per-workload size."
  }
  assert {
    condition     = aws_dlm_lifecycle_policy.data.policy_details[0].schedule[0].retain_rule[0].count == 3
    error_message = "Daily snapshots keep 3."
  }
}

run "user_data_has_no_secret_values" {
  command = apply

  assert {
    condition     = !can(regex("(?i)password=|BEGIN .*PRIVATE|AKIA[0-9A-Z]{12}", aws_instance.this.user_data))
    error_message = "user_data must not embed secret material."
  }
  assert {
    condition     = can(regex("get-secret-value", aws_instance.this.user_data)) && can(regex("pulso-stack", aws_instance.this.user_data))
    error_message = "user_data installs the start script and unit."
  }
}

run "kill_switch_stops_instance" {
  command = apply
  variables {
    enabled = false
  }
  assert {
    condition     = aws_ec2_instance_state.this.state == "stopped"
    error_message = "enabled=false stops the instance."
  }
}

run "image_must_be_digest_pinned" {
  command = plan
  variables {
    images = {
      core = "x/agent-core:latest"
    }
  }
  expect_failures = [var.images]
}

run "workload_must_be_known" {
  command = plan
  variables {
    workload = "other"
  }
  expect_failures = [var.workload]
}
