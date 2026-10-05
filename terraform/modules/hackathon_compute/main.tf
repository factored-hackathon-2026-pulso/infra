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
  bundle_root    = coalesce(var.bundle_dir, "${path.module}/../../../deploy/hackathon")
  bundle_dir     = "${local.bundle_root}/${var.workload}"
  deploy_script  = file("${local.bundle_root}/deploy-stack.sh")
  compose_text   = file("${local.bundle_dir}/compose.yaml")
  caddyfile_text = try(file("${local.bundle_dir}/Caddyfile"), null)
  compose        = yamldecode(local.compose_text)
  name           = "${var.name_prefix}-${var.workload}"
  tags           = merge(var.tags, { Module = "hackathon_compute", Workload = var.workload })

  memory_by_type = {
    "t3.micro"       = 1024, "t3.small" = 2048, "t3.medium" = 4096, "t3.large" = 8192,
    "t4g.micro"      = 1024, "t4g.small" = 2048, "t8i.micro" = 1024, "t8i.small" = 2048,
    "c7i-flex.large" = 4096, "m7i-flex.large" = 8192,
  }
  has_db_volume      = var.db_volume_size_gb > 0
  instance_memory_mb = lookup(local.memory_by_type, var.instance_type, 2048)
  allowed_ports      = concat({ core = concat(["8000:8000"], var.db_volume_size_gb > 0 ? ["5432:5432"] : []), platform = ["80:80"], engine = ["8080:8080"] }[var.workload], var.extra_ports)
  bundle_key_prefix  = "${var.bundle_prefix}${var.workload}/"

  service_env_names = concat({
    core     = ["common", "core", "gateway"]
    platform = ["common", "support"]
    engine   = ["common", "pulso"]
  }[var.workload], var.extra_service_envs)

  db_volume_id   = local.has_db_volume ? (var.protect_data_volume ? aws_ebs_volume.db_protected[0].id : aws_ebs_volume.db_unprotected[0].id) : ""
  data_volume_id = var.protect_data_volume ? aws_ebs_volume.data_protected[0].id : aws_ebs_volume.data_unprotected[0].id
  log_group      = "/${var.name_prefix}/docker"

  prepare_script = templatefile("${path.module}/templates/prepare.sh.tftpl", {
    region        = var.region
    bucket        = var.bucket_name
    bundle_prefix = local.bundle_key_prefix
    services      = join(" ", local.service_env_names)
    svc_regex     = join("|", [for s in local.service_env_names : upper(s)])
    secret_arn    = var.secret_arn
    ssm_prefix    = var.ssm_prefix
    workload      = var.workload
    registry      = var.ecr_registry_url
    # tool-service reads data-pipeline's publication from local disk: synced at every start (agent services).
    sync_publication   = contains(local.service_env_names, "tools")
    sync_artifacts     = contains(local.service_env_names, "agent")
    publication_prefix = trim(var.publication_prefix, "/")
  })

  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    compose_version       = var.compose_version
    data_volume_id_nodash = replace(local.data_volume_id, "-", "")
    db_volume_id_nodash   = local.has_db_volume ? replace(local.db_volume_id, "-", "") : ""
    prepare_script        = local.prepare_script
    cloudwatch            = var.enable_cloudwatch_agent
    log_group             = local.log_group
  })

  # No image references here: the start script resolves <KEY>_IMAGE from SSM (aws_ssm_parameter.image), so a new
  # digest never changes this object, the start script or the instance.
  env_text = join("\n", concat([
    "BUCKET_NAME=${var.bucket_name}",
    "CORE_BLOB_PREFIX=core/blobs/",
    "PULSO_STORAGE_PREFIX=engine/",
    "PRIVATE_ZONE_NAME=${trimsuffix(data.aws_route53_zone.private.name, ".")}",
    ],
    length(var.compose_files) > 1 ? ["COMPOSE_FILE=${join(":", var.compose_files)}"] : [],
    [for k in sort(keys(var.extra_env)) : "${k}=${var.extra_env[k]}"],
    [""],
  ))

  deploy_document_name = "pulso-deploy-${var.workload}"
}

resource "aws_instance" "this" {
  ami                         = data.aws_ssm_parameter.ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  vpc_security_group_ids      = var.security_group_ids
  iam_instance_profile        = var.instance_profile_name
  associate_public_ip_address = var.associate_public_ip
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

  # A stopped instance has no public IP, so the provider reads associate_public_ip_address back as false; that attribute
  # is ForceNew, and without this a re-plan of an inactive (enabled=false) host would REPLACE the instance.
  lifecycle {
    ignore_changes = [associate_public_ip_address]
  }
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

# Postgres container data volume (free_plan database_mode=container); same Snapshot tag, so the daily DLM policy covers it.
resource "aws_ebs_volume" "db_protected" {
  count             = local.has_db_volume && var.protect_data_volume ? 1 : 0
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.db_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.tags, { Name = "${local.name}-pgdata", Snapshot = "${local.name}-daily" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_ebs_volume" "db_unprotected" {
  count             = local.has_db_volume && !var.protect_data_volume ? 1 : 0
  availability_zone = data.aws_subnet.this.availability_zone
  size              = var.db_volume_size_gb
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.tags, { Name = "${local.name}-pgdata", Snapshot = "${local.name}-daily" })
}

resource "aws_volume_attachment" "db" {
  count       = local.has_db_volume ? 1 : 0
  device_name = "/dev/sdg"
  volume_id   = local.db_volume_id
  instance_id = aws_instance.this.id
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = local.data_volume_id
  instance_id = aws_instance.this.id
}

# Inactive hosts are created RUNNING (EBS volumes attach only to a running instance, and user_data needs a boot to be
# valid) and are stopped here, strictly after both attachments exist.
resource "aws_ec2_instance_state" "this" {
  instance_id = aws_instance.this.id
  state       = var.enabled ? "running" : "stopped"

  depends_on = [aws_volume_attachment.data, aws_volume_attachment.db]
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

resource "aws_s3_object" "extra" {
  for_each = var.extra_bundle_files
  bucket   = var.bucket_name
  key      = "${local.bundle_key_prefix}${each.key}"
  content  = each.value
}

resource "aws_s3_object" "env" {
  bucket  = var.bucket_name
  key     = "${local.bundle_key_prefix}.env"
  content = local.env_text
}

resource "aws_s3_object" "deploy_script" {
  bucket       = var.bucket_name
  key          = "${local.bundle_key_prefix}deploy-stack.sh"
  content      = local.deploy_script
  content_type = "text/x-shellscript"
}

# Image digests. Terraform seeds each parameter from var.images and then ignores the value: deployments
# (scripts/aws-prod.ps1 deploy, or a team's CI) write new digests, and a later apply does not revert them.
resource "aws_ssm_parameter" "image" {
  for_each = var.images
  name     = "${var.ssm_prefix}/${var.workload}/images/${each.key}"
  type     = "String"
  value    = each.value
  tags     = local.tags

  lifecycle {
    ignore_changes = [value]
  }
}

# Run Command document that deploys the digests currently stored in SSM on this host (target: instance tag Workload).
resource "aws_ssm_document" "deploy" {
  name            = local.deploy_document_name
  document_type   = "Command"
  document_format = "JSON"
  tags            = local.tags
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy the image digests stored in SSM Parameter Store on the ${var.workload} host (no instance replacement)."
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deployStack"
      inputs = {
        timeoutSeconds = "900"
        runCommand = [
          "set -eu",
          "aws s3 cp s3://${var.bucket_name}/${local.bundle_key_prefix}deploy-stack.sh /srv/stack/deploy-stack.sh --region ${var.region} --only-show-errors",
          "bash /srv/stack/deploy-stack.sh",
        ]
      }
    }]
  })
}

resource "aws_route53_record" "this" {
  zone_id = var.private_zone_id
  name    = "${var.workload}.${trimsuffix(data.aws_route53_zone.private.name, ".")}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.this.private_ip]
}
