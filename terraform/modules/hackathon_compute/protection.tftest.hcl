mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/pulso-hk-dlm"
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
}

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
    core_runtime = "123456789012.dkr.ecr.us-east-1.amazonaws.com/agent-core@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    llm_gateway  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/llm-gateway@sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    support_api  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    support_web  = "123456789012.dkr.ecr.us-east-1.amazonaws.com/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    pulso        = "123456789012.dkr.ecr.us-east-1.amazonaws.com/pulso@sha256:eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
    proxy        = "123456789012.dkr.ecr.us-east-1.amazonaws.com/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
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

