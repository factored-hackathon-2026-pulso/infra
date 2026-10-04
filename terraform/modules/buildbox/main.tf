data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  bucket     = "${var.name_prefix}-buildbox-${local.account_id}"
  tags       = merge(var.tags, { Purpose = "buildbox", Ephemeral = "true" })
}

resource "aws_security_group" "this" {
  name_prefix = "pulso-buildbox-"
  description = "buildbox: no ingress, egress all (SSM only)"
  vpc_id      = var.vpc_id
  tags        = merge(local.tags, { Name = "pulso-buildbox" })

  # Intentionally no ingress blocks.
  egress {
    description = "all egress (package mirrors, crates.io, S3, SSM)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_instance" "this" {
  ami                                  = data.aws_ssm_parameter.al2023.value
  instance_type                        = var.instance_type
  subnet_id                            = var.subnet_id
  vpc_security_group_ids               = [aws_security_group.this.id]
  iam_instance_profile                 = aws_iam_instance_profile.this.name
  associate_public_ip_address          = true
  instance_initiated_shutdown_behavior = "stop"
  user_data_replace_on_change          = false
  monitoring                           = false

  # Normalise CRLF (Windows checkouts) so the shebang line stays valid on Linux.
  user_data = replace(templatefile("${path.module}/user_data.sh.tftpl", {
    idle_minutes = var.idle_minutes
    bucket       = local.bucket
    region       = var.region
  }), "\r\n", "\n")

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.root_volume_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = local.tags
  }

  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_type           = "gp3"
    volume_size           = var.data_volume_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = local.tags
  }

  tags = merge(local.tags, { Name = "pulso-buildbox" })
}
