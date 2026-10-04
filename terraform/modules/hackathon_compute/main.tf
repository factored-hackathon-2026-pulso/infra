data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

data "aws_subnet" "this" {
  id = var.subnet_id
}

locals {
  bundle_dir     = coalesce(var.bundle_dir, "${path.module}/../../../deploy/hackathon")
  compose_text   = file("${local.bundle_dir}/compose.yaml")
  caddyfile_text = file("${local.bundle_dir}/Caddyfile")
  compose        = yamldecode(local.compose_text)
  tags           = merge(var.tags, { Module = "hackathon_compute" })

  data_volume_id = var.protect_data_volume ? aws_ebs_volume.data_protected[0].id : aws_ebs_volume.data_unprotected[0].id
  log_group      = "/${trimprefix(var.ssm_prefix, "/")}/docker"

  prepare_script = templatefile("${path.module}/templates/prepare.sh.tftpl", {
    region        = var.region
    bucket        = var.bucket_name
    bundle_prefix = var.bundle_prefix
    secret_arn    = var.secret_arn
    ssm_prefix    = var.ssm_prefix
    registry      = var.ecr_registry_url
  })

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    compose_version       = var.compose_version
    data_volume_id_nodash = replace(local.data_volume_id, "-", "")
    prepare_script        = local.prepare_script
    cloudwatch            = var.enable_cloudwatch_agent
    log_group             = local.log_group
  })

  env_text = <<-EOT
    CORE_IMAGE=${var.images.core_runtime}
    GATEWAY_IMAGE=${var.images.llm_gateway}
    SUPPORT_API_IMAGE=${var.images.support_api}
    SUPPORT_WEB_IMAGE=${var.images.support_web}
    PULSO_IMAGE=${var.images.pulso}
    PROXY_IMAGE=${var.images.proxy}
    BUCKET_NAME=${var.bucket_name}
    CORE_BLOB_PREFIX=core/blobs/
    PULSO_STORAGE_PREFIX=engine/
  EOT
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = false
  ebs_optimized               = true
  user_data                   = local.user_data
  user_data_replace_on_change = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "${var.name_prefix}-host" })
}

resource "aws_ebs_volume" "data_protected" {
  count             = var.protect_data_volume ? 1 : 0
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.tags, { Name = "${var.name_prefix}-data", Snapshot = "${var.name_prefix}-daily" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ebs_volume" "data_unprotected" {
  count             = var.protect_data_volume ? 0 : 1
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.tags, { Name = "${var.name_prefix}-data", Snapshot = "${var.name_prefix}-daily" })
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = local.data_volume_id
  instance_id = aws_instance.this.id
}

resource "aws_ec2_instance_state" "this" {
  instance_id = aws_instance.this.id
  state       = var.enabled ? "running" : "stopped"
}

data "aws_iam_policy_document" "dlm_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dlm" {
  name               = "${var.name_prefix}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "${var.name_prefix} daily data volume snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "${var.name_prefix}-daily" }

    schedule {
      name = "daily"
      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["06:00"]
      }
      retain_rule {
        count = 3
      }
      copy_tags = true
    }
  }
  tags = local.tags
}

# Compose bundle published to the single bucket; no secrets inside.
resource "aws_s3_object" "compose" {
  bucket       = var.bucket_name
  key          = "${var.bundle_prefix}compose.yaml"
  content      = local.compose_text
  content_type = "text/yaml"
}

resource "aws_s3_object" "caddyfile" {
  bucket  = var.bucket_name
  key     = "${var.bundle_prefix}Caddyfile"
  content = local.caddyfile_text
}

resource "aws_s3_object" "env" {
  bucket  = var.bucket_name
  key     = "${var.bundle_prefix}.env"
  content = local.env_text
}
