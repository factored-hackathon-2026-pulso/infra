data "aws_ssm_parameter" "ami" {
  name = var.ami_ssm_parameter
}

data "aws_subnet" "this" {
  id = var.subnet_id
}

data "aws_route53_zone" "private" {
  zone_id      = var.private_zone_id
  private_zone = true
}

locals {
  bundle_dir     = "${coalesce(var.bundle_dir, "${path.module}/../../../deploy/hackathon")}/${var.workload}"
  compose_text   = file("${local.bundle_dir}/compose.yaml")
  caddyfile_text = try(file("${local.bundle_dir}/Caddyfile"), null)
  compose        = yamldecode(local.compose_text)
  name           = "${var.name_prefix}-${var.workload}"
  tags           = merge(var.tags, { Module = "hackathon_compute", Workload = var.workload })

  memory_by_type     = { "t3.micro" = 1024, "t3.small" = 2048, "t3.medium" = 4096, "t3.large" = 8192 }
  instance_memory_mb = lookup(local.memory_by_type, var.instance_type, 2048)
  allowed_ports      = var.workload == "core" ? ["8000:8000"] : ["80:80"]
  bundle_key_prefix  = "${var.bundle_prefix}${var.workload}/"

  service_env_names = {
    core     = ["common", "core", "gateway"]
    platform = ["common", "support"]
    engine   = ["common", "pulso"]
  }[var.workload]

  data_volume_id = var.protect_data_volume ? aws_ebs_volume.data_protected[0].id : aws_ebs_volume.data_unprotected[0].id
  log_group      = "/${trimprefix(var.ssm_prefix, "/")}/docker"

  prepare_script = templatefile("${path.module}/templates/prepare.sh.tftpl", {
    region        = var.region
    bucket        = var.bucket_name
    bundle_prefix = local.bundle_key_prefix
    services      = join(" ", local.service_env_names)
    svc_regex     = join("|", [for s in local.service_env_names : upper(s)])
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

  env_text = join("\n", concat(
    [for k, v in var.images : "${upper(k)}_IMAGE=${v}"],
    [
      "BUCKET_NAME=${var.bucket_name}",
      "CORE_BLOB_PREFIX=core/blobs/",
      "PULSO_STORAGE_PREFIX=engine/",
      "PRIVATE_ZONE_NAME=${trimsuffix(data.aws_route53_zone.private.name, ".")}",
      "",
    ],
  ))
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

  tags = merge(local.tags, { Name = "${local.name}-host" })
}

resource "aws_ebs_volume" "data_protected" {
  count             = var.protect_data_volume ? 1 : 0
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.data_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.tags, { Name = "${local.name}-data", Snapshot = "${local.name}-daily" })

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
  tags              = merge(local.tags, { Name = "${local.name}-data", Snapshot = "${local.name}-daily" })
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
  name               = "${local.name}-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "data" {
  description        = "${local.name} daily data volume snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]
    target_tags    = { Snapshot = "${local.name}-daily" }

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
  key          = "${local.bundle_key_prefix}compose.yaml"
  content      = local.compose_text
  content_type = "text/yaml"
}

resource "aws_s3_object" "caddyfile" {
  count   = local.caddyfile_text == null ? 0 : 1
  bucket  = var.bucket_name
  key     = "${local.bundle_key_prefix}Caddyfile"
  content = local.caddyfile_text
}

resource "aws_s3_object" "env" {
  bucket  = var.bucket_name
  key     = "${local.bundle_key_prefix}.env"
  content = local.env_text
}

resource "aws_route53_record" "this" {
  zone_id = var.private_zone_id
  name    = "${var.workload}.${trimsuffix(data.aws_route53_zone.private.name, ".")}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.this.private_ip]
}
