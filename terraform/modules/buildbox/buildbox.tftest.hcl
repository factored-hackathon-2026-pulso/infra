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
  mock_data "aws_ssm_parameter" {
    defaults = {
      value = "ami-0123456789abcdef0"
    }
  }
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}

variables {
  vpc_id    = "vpc-0123456789abcdef0"
  subnet_id = "subnet-0123456789abcdef0"
}

run "network_has_no_ingress_and_no_keypair" {
  command = apply

  assert {
    condition     = length(aws_security_group.this.ingress) == 0
    error_message = "the security group must have no ingress rules"
  }
  assert {
    condition     = length(aws_security_group.this.egress) == 1
    error_message = "egress is all-allow in a single rule"
  }
  assert {
    condition     = aws_instance.this.associate_public_ip_address == true
    error_message = "default public subnet, no NAT: the instance needs a public IP for egress"
  }
}

run "instance_is_hardened_and_ephemeral" {
  command = apply

  assert {
    condition     = aws_instance.this.instance_type == "c6i.2xlarge"
    error_message = "default instance type is c6i.2xlarge"
  }
  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required"
    error_message = "IMDSv2 required"
  }
  assert {
    condition     = aws_instance.this.instance_initiated_shutdown_behavior == "stop"
    error_message = "shutdown from inside the box must stop, not terminate"
  }
  assert {
    condition     = aws_instance.this.root_block_device[0].encrypted == true && aws_instance.this.root_block_device[0].delete_on_termination == true && aws_instance.this.root_block_device[0].volume_size == 40
    error_message = "root volume: encrypted, 40 GB, delete on termination"
  }
  assert {
    condition     = one([for d in aws_instance.this.ebs_block_device : d.encrypted && d.delete_on_termination && d.volume_size == 100 && d.volume_type == "gp3"])
    error_message = "data volume: encrypted gp3 100 GB, delete on termination"
  }
  assert {
    condition     = aws_instance.this.iam_instance_profile != null
    error_message = "instance profile attached"
  }
}

run "bucket_is_disposable_and_private" {
  command = apply

  assert {
    condition     = aws_s3_bucket.this.bucket == "pulso-prod-buildbox-123456789012"
    error_message = "bucket name derives from the account id"
  }
  assert {
    condition     = aws_s3_bucket.this.force_destroy == true
    error_message = "force_destroy so terraform destroy leaves nothing"
  }
  assert {
    condition     = aws_s3_bucket_lifecycle_configuration.this.rule[0].expiration[0].days == 7 && aws_s3_bucket_lifecycle_configuration.this.rule[0].status == "Enabled"
    error_message = "7 day expiry"
  }
  assert {
    condition     = aws_s3_bucket_public_access_block.this.block_public_acls && aws_s3_bucket_public_access_block.this.block_public_policy && aws_s3_bucket_public_access_block.this.ignore_public_acls && aws_s3_bucket_public_access_block.this.restrict_public_buckets
    error_message = "all public access blocked"
  }
  assert {
    condition     = one(aws_s3_bucket_server_side_encryption_configuration.this.rule[*].apply_server_side_encryption_by_default[0].sse_algorithm) == "AES256"
    error_message = "SSE-S3"
  }
  assert {
    condition     = aws_s3_bucket_versioning.this.versioning_configuration[0].status == "Disabled"
    error_message = "versioning off"
  }
  assert {
    condition     = strcontains(aws_s3_bucket_policy.this.policy, "aws:SecureTransport") && !strcontains(aws_s3_bucket_policy.this.policy, "\"Principal\":\"*\",\"Resource\":[\"arn:aws:s3:::pulso-prod-buildbox-123456789012/*\"],\"Effect\":\"Allow\"")
    error_message = "TLS-only policy, no public allow"
  }
}

run "user_policy_is_scoped" {
  command = apply

  assert {
    condition     = aws_iam_user.this.name == "pulso-buildbox"
    error_message = "scoped IAM user"
  }
  assert {
    condition     = length(aws_iam_user.this.tags) > 0
    error_message = "user tagged"
  }
  assert {
    condition     = output.user_policy_json == aws_iam_user_policy.this.policy
    error_message = "policy JSON is exported"
  }
  assert {
    condition = alltrue([for s in jsondecode(output.user_policy_json).Statement :
      !(length(setintersection(toset(flatten([s.Action])), toset(["ssm:SendCommand", "ec2:StartInstances", "ec2:StopInstances", "s3:GetObject", "s3:PutObject", "s3:ListBucket"]))) > 0
    && contains(flatten([s.Resource]), "*"))])
    error_message = "no wildcard resource on SendCommand / Start / Stop / S3"
  }
  assert {
    condition = alltrue([for s in jsondecode(output.user_policy_json).Statement :
    !contains(flatten([s.Resource]), "*") || length(setsubtract(toset(flatten([s.Action])), toset(["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation", "ec2:DescribeInstances", "tag:GetResources"]))) == 0])
    error_message = "wildcard resources only for read-only actions that do not support resource-level permissions"
  }
  assert {
    condition = anytrue([for s in jsondecode(output.user_policy_json).Statement :
      contains(flatten([s.Action]), "ssm:SendCommand") && length(flatten([s.Resource])) == 2
      && anytrue([for r in flatten([s.Resource]) : endswith(r, ":document/AWS-RunShellScript")])
    && anytrue([for r in flatten([s.Resource]) : strcontains(r, ":instance/")])])
    error_message = "SendCommand limited to the RunShellScript document and this instance"
  }
  assert {
    condition = anytrue([for s in jsondecode(output.user_policy_json).Statement :
      contains(flatten([s.Action]), "ec2:StartInstances") && contains(flatten([s.Action]), "ec2:StopInstances")
    && try(s.Condition.StringEquals["aws:ResourceTag/Purpose"], "") == "buildbox"])
    error_message = "start/stop conditioned on tag Purpose=buildbox"
  }
  assert {
    condition     = !strcontains(output.user_policy_json, "s3:*") && !strcontains(output.user_policy_json, "iam:")
    error_message = "no broad actions"
  }
}

run "instance_role_is_least_privilege" {
  command = apply

  assert {
    condition     = aws_iam_role_policy_attachment.ssm.policy_arn == "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    error_message = "AmazonSSMManagedInstanceCore attached"
  }
  assert {
    condition     = !strcontains(aws_iam_role_policy.s3.policy, "\"s3:*\"") && strcontains(aws_iam_role_policy.s3.policy, "pulso-prod-buildbox-123456789012")
    error_message = "instance S3 access limited to the buildbox bucket"
  }
}

run "everything_is_tagged" {
  command = apply

  assert {
    condition = alltrue([for t in [aws_instance.this.tags, aws_security_group.this.tags, aws_s3_bucket.this.tags, aws_iam_role.this.tags, aws_iam_user.this.tags] :
    t["Purpose"] == "buildbox" && t["Ephemeral"] == "true"])
    error_message = "Purpose=buildbox and Ephemeral=true on everything"
  }
  assert {
    condition     = strcontains(output.how_to_remove, "terraform destroy") && strcontains(output.how_to_remove, "verify-gone")
    error_message = "how_to_remove explains removal"
  }
  assert {
    condition     = output.user_name == "pulso-buildbox" && output.bucket == "pulso-prod-buildbox-123456789012"
    error_message = "outputs"
  }
}

run "user_data_installs_the_toolchain" {
  command = apply

  assert {
    condition     = alltrue([for k in ["rustup", "nodejs", "python3.12", "uv", "docker", "jq", "/work", "buildbox-idle", "lld", "openssl-devel", "awscli"] : strcontains(aws_instance.this.user_data, k)])
    error_message = "user_data installs git/gcc/lld/openssl/rustup/node/python/uv/docker/jq/awscli and the idle timer"
  }
  assert {
    condition     = strcontains(aws_instance.this.user_data, "/work/.jobs") && strcontains(aws_instance.this.user_data, "30")
    error_message = "idle shutdown watches /work/.jobs with a 30 minute threshold"
  }
}


