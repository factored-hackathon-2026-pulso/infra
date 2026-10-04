mock_provider "aws" {}

variables {
  name_prefix           = "pulso-hk"
  region                = "us-east-1"
  subnet_id             = "subnet-0123456789abcdef0"
  security_group_ids    = ["sg-0123456789abcdef0"]
  instance_profile_name = "pulso-hk-host"
  ssm_prefix            = "/pulso-hk"
  bucket_name           = "pulso-hk-data"
  secret_arn            = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-hk-abc123"
  kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  ecr_registry_url      = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  images = {
    core_runtime     = "123456789012.dkr.ecr.us-east-1.amazonaws.com/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    llm_gateway      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    support_api      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    support_web      = "123456789012.dkr.ecr.us-east-1.amazonaws.com/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    pulso            = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    proxy            = "123456789012.dkr.ecr.us-east-1.amazonaws.com/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  }
}

run "defaults_are_hardened" {
  command = plan

  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 must be required."
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted && aws_instance.this.associate_public_ip_address == false
    error_message = "Root volume must be encrypted and the host private."
  }
  assert {
    condition     = aws_instance.this.key_name == null
    error_message = "No SSH key pair: access is SSM Session Manager only."
  }
  assert {
    condition     = aws_instance.this.instance_type == "t3.large"
    error_message = "Default instance type is t3.large."
  }
}

run "data_volume_encrypted_protected_and_snapshotted" {
  command = plan

  assert {
    condition     = aws_ebs_volume.data_protected[0].encrypted && aws_ebs_volume.data_protected[0].type == "gp3" && aws_ebs_volume.data_protected[0].size == 40
    error_message = "Data volume must be an encrypted 40 GB gp3."
  }
  assert {
    condition     = length(aws_ebs_volume.data_unprotected) == 0
    error_message = "Protected volume is the default."
  }
  assert {
    condition     = aws_dlm_lifecycle_policy.data.policy_details[0].schedule[0].retain_rule[0].count == 3
    error_message = "Daily snapshots keep 3."
  }
}

run "unprotected_volume_toggle" {
  command = plan
  variables {
    protect_data_volume = false
  }
  assert {
    condition     = length(aws_ebs_volume.data_unprotected) == 1 && length(aws_ebs_volume.data_protected) == 0
    error_message = "protect_data_volume=false selects the destroyable volume."
  }
}

run "user_data_has_no_secret_values" {
  command = plan

  assert {
    condition     = !can(regex("(?i)password|BEGIN .*PRIVATE|AKIA[0-9A-Z]{12}", aws_instance.this.user_data))
    error_message = "user_data must not embed secret material."
  }
  assert {
    condition     = can(regex("get-secret-value", aws_instance.this.user_data)) && can(regex("pulso-stack", aws_instance.this.user_data))
    error_message = "user_data installs the start script and systemd unit."
  }
}

run "compose_bundle_rules" {
  command = plan

  assert {
    condition     = !can(regex(":latest", local.compose_text))
    error_message = "No :latest tags."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : (n == "proxy" ? s.ports == ["80:80"] : !contains(keys(s), "ports"))])
    error_message = "Only the proxy publishes a port, and only 80."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : can(regex("^[0-9]+m$", s.mem_limit))])
    error_message = "Every service has a memory limit in MB."
  }
  assert {
    condition     = sum([for n, s in local.compose.services : tonumber(trimsuffix(s.mem_limit, "m"))]) <= 6500
    error_message = "Memory limits must leave headroom under 8 GB host RAM."
  }
  assert {
    condition     = alltrue([for n, s in local.compose.services : contains(keys(s), "restart")])
    error_message = "Every service has a restart policy."
  }
  assert {
    condition     = can(regex("/internal", local.caddyfile_text))
    error_message = "Proxy must block /internal routes."
  }
}

run "kill_switch_stops_instance" {
  command = plan
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
      core_runtime = "x/agent-core:latest"
      llm_gateway  = "x/g@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      support_api  = "x/a@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
      support_web  = "x/w@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
      pulso        = "x/p@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
      proxy        = "x/c@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
    }
  }
  expect_failures = [var.images]
}
