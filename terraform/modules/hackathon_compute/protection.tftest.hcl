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
    core        = "r/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    gateway     = "r/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    pulso       = "r/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
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

# An inactive host (enabled=false) is created like any other and then stopped; toggling never replaces the instance.
run "inactive_host_is_created_with_both_attachments" {
  command = apply
  variables {
    enabled             = false
    associate_public_ip = true
    db_volume_size_gb   = 20
  }
  assert {
    condition     = aws_ec2_instance_state.this.state == "stopped"
    error_message = "enabled=false ends stopped."
  }
  assert {
    condition     = aws_volume_attachment.data.device_name == "/dev/sdf" && length(aws_volume_attachment.db) == 1
    error_message = "the data and the Postgres volumes are attached to an inactive host."
  }
}

run "enable_the_same_host" {
  command = apply
  variables {
    enabled             = true
    associate_public_ip = true
    db_volume_size_gb   = 20
  }
  assert {
    condition     = aws_ec2_instance_state.this.state == "running"
    error_message = "enabled=true starts the host."
  }
}

run "disable_again_keeps_the_instance" {
  command = apply
  variables {
    enabled             = false
    associate_public_ip = true
    db_volume_size_gb   = 20
  }
  assert {
    condition     = aws_ec2_instance_state.this.state == "stopped" && aws_instance.this.id == run.enable_the_same_host.instance_id
    error_message = "toggling enabled never replaces the instance (same instance id across toggles)."
  }
  assert {
    condition     = aws_volume_attachment.data.instance_id == run.enable_the_same_host.instance_id
    error_message = "attachments keep pointing at the same instance."
  }
}
