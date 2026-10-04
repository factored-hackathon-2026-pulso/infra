# Deploying a new image digest must never replace an instance: digests live in SSM Parameter Store, the host start
# script resolves them, and a custom SSM Command document runs deploy-stack.sh on the host.
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
  mock_resource "aws_ebs_volume" {
    defaults = {
      id = "vol-0123456789abcdef0"
    }
  }
  mock_resource "aws_instance" {
    defaults = {
      arn = "arn:aws:ec2:us-east-1:123456789012:instance/i-0123456789abcdef0"
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
  workload              = "platform"
  subnet_id             = "subnet-0123456789abcdef0"
  security_group_ids    = ["sg-0123456789abcdef0"]
  instance_profile_name = "pulso-hk-platform"
  private_zone_id       = "Z0123456789ABCDEFGHIJ"
  ssm_prefix            = "/pulso"
  bucket_name           = "pulso-hk-data"
  secret_arn            = "arn:aws:secretsmanager:us-east-1:123456789012:secret:pulso-hk-abc123"
  kms_key_arn           = "arn:aws:kms:us-east-1:123456789012:key/11111111-2222-3333-4444-555555555555"
  ecr_registry_url      = "123456789012.dkr.ecr.us-east-1.amazonaws.com"
  images = {
    support_api = "r/support-api@sha256:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
    support_web = "r/support-web@sha256:dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
    proxy       = "r/caddy@sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
  }
}

run "digests_a" {
  command = apply
}

run "other_digests_do_not_touch_user_data_or_ami" {
  command = apply
  variables {
    images = {
      support_api = "r/support-api@sha256:1111111111111111111111111111111111111111111111111111111111111111"
      support_web = "r/support-web@sha256:2222222222222222222222222222222222222222222222222222222222222222"
      proxy       = "r/caddy@sha256:3333333333333333333333333333333333333333333333333333333333333333"
    }
  }

  assert {
    condition     = output.user_data_sha256 == run.digests_a.user_data_sha256
    error_message = "user_data (and so the instance, user_data_replace_on_change) must not depend on image digests."
  }
  assert {
    condition     = aws_instance.this.ami == run.digests_a.ami_id
    error_message = "The AMI must not depend on image digests."
  }
  assert {
    condition     = !strcontains(aws_instance.this.user_data, "@sha256")
    error_message = "No digest in user_data."
  }
}

run "image_parameters_seed_each_image_under_the_workload_path" {
  command = apply

  assert {
    condition     = toset(keys(aws_ssm_parameter.image)) == toset(["support_api", "support_web", "proxy"])
    error_message = "One SSM parameter per image key."
  }
  assert {
    condition     = aws_ssm_parameter.image["support_api"].name == "/pulso/platform/images/support_api" && aws_ssm_parameter.image["proxy"].name == "/pulso/platform/images/proxy"
    error_message = "Name is <ssm_prefix>/<workload>/images/<service key>."
  }
  assert {
    condition     = alltrue([for k, p in aws_ssm_parameter.image : p.type == "String" && can(regex("@sha256:[0-9a-f]{64}$", p.value))])
    error_message = "Plain String parameters (free tier) holding the digest-pinned reference."
  }
}

run "env_bundle_carries_no_image_references" {
  command = apply

  assert {
    condition     = !strcontains(aws_s3_object.env.content, "_IMAGE=") && !strcontains(aws_s3_object.env.content, "@sha256")
    error_message = "The bundle .env must not pin images: the host resolves them from SSM at start."
  }
  assert {
    condition     = strcontains(aws_s3_object.env.content, "BUCKET_NAME=pulso-hk-data")
    error_message = "Non-image environment stays in the bundle."
  }
}

run "start_script_resolves_digests_from_ssm" {
  command = apply

  assert {
    condition     = strcontains(local.prepare_script, "SSM_PREFIX/images") && strcontains(local.prepare_script, "_IMAGE=")
    error_message = "pulso-stack-prepare renders <SERVICE>_IMAGE=<ref> into .env from <ssm_prefix>/<workload>/images/*."
  }
}

run "deploy_script_is_shipped_in_the_bundle" {
  command = apply

  assert {
    condition     = aws_s3_object.deploy_script.key == "engine/deploy/platform/deploy-stack.sh"
    error_message = "deploy-stack.sh is published next to compose.yaml."
  }
  assert {
    condition     = strcontains(aws_s3_object.deploy_script.content, "compose pull") && strcontains(aws_s3_object.deploy_script.content, "previous-images.env") && strcontains(aws_s3_object.deploy_script.content, "DEPLOY_RESULT=")
    error_message = "The script pulls, keeps a local state file for rollback and reports a result line."
  }
}

run "ssm_command_document_runs_the_deploy_script" {
  command = apply

  assert {
    condition     = aws_ssm_document.deploy.name == "pulso-deploy-platform" && aws_ssm_document.deploy.document_type == "Command"
    error_message = "Custom Command document pulso-deploy-<workload>."
  }
  assert {
    condition     = jsondecode(aws_ssm_document.deploy.content).schemaVersion == "2.2" && strcontains(aws_ssm_document.deploy.content, "deploy-stack.sh")
    error_message = "The document runs deploy-stack.sh."
  }
  assert {
    condition     = output.deploy_document_name == "pulso-deploy-platform"
    error_message = "deploy_document_name output for the deployer policies."
  }
}

run "outputs_name_the_image_parameters" {
  command = apply

  assert {
    condition     = output.image_parameter_names["support_web"] == "/pulso/platform/images/support_web"
    error_message = "image_parameter_names output."
  }
}

run "instance_still_replaces_only_on_user_data_change" {
  command = apply

  assert {
    condition     = aws_instance.this.user_data_replace_on_change == true
    error_message = "Kept: a changed start script replaces the host (data volume survives). Digests never change it."
  }
}
