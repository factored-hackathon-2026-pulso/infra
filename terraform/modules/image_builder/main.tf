# AWS CodeBuild image builder: builds (or mirrors) a container image from a source zip in the single bucket and
# pushes it to ECR, then records {image, digest} under <output_prefix>/<service>/<id>.json. Nothing here deploys.
# Off by default (var.enabled). One project and one role per service, so a role can push to its own repository only.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  bucket_arn = "arn:${local.partition}:s3:::${var.bucket_name}"
  tags       = merge(var.tags, { Module = "image_builder" })

  active = var.enabled ? var.services : {}

  project_names = { for k, v in local.active : k => "${var.name}-build-${k}" }
  log_groups    = { for k, v in local.active : k => "/aws/codebuild/${var.name}-build-${k}" }
}

resource "aws_cloudwatch_log_group" "build" {
  for_each          = local.active
  name              = local.log_groups[each.key]
  retention_in_days = var.log_retention_days
  tags              = local.tags
}

resource "aws_iam_role" "build" {
  for_each = local.active
  name     = "${var.name}-build-${each.key}"
  tags     = local.tags
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "codebuild.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "build" {
  for_each = local.active
  name     = "build"
  role     = aws_iam_role.build[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [
        {
          Sid      = "EcrToken"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*" # the API does not support resource-level scoping
        },
        {
          Sid    = "EcrPush"
          Effect = "Allow"
          Action = [
            "ecr:BatchCheckLayerAvailability",
            "ecr:CompleteLayerUpload",
            "ecr:DescribeImages",
            "ecr:InitiateLayerUpload",
            "ecr:PutImage",
            "ecr:UploadLayerPart",
          ]
          Resource = "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${each.value.repository}"
        },
        {
          Sid      = "WriteBuildOutput"
          Effect   = "Allow"
          Action   = "s3:PutObject"
          Resource = "${local.bucket_arn}/${var.output_prefix}/${each.key}/*"
        },
        {
          Sid      = "UseDataKey"
          Effect   = "Allow"
          Action   = ["kms:Decrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
          Resource = var.kms_key_arn
        },
        {
          Sid      = "WriteLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
          Resource = "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:${local.log_groups[each.key]}:*"
        },
      ],
      each.value.mode == "build" ? [
        {
          Sid      = "ReadSource"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:GetObjectVersion"]
          Resource = "${local.bucket_arn}/${var.source_prefix}/${each.key}/*"
        },
        {
          Sid      = "ReadBucketInfo"
          Effect   = "Allow"
          Action   = ["s3:GetBucketLocation", "s3:GetBucketVersioning"]
          Resource = local.bucket_arn
        },
      ] : [],
    )
  })
}

resource "aws_codebuild_project" "this" {
  for_each      = local.active
  name          = local.project_names[each.key]
  description   = "Builds ${each.key} from a source zip in S3 and pushes it to ECR (${each.value.repository}). Records the digest; does not deploy."
  service_role  = aws_iam_role.build[each.key].arn
  build_timeout = coalesce(each.value.timeout_mins, var.timeout_mins)
  tags          = local.tags

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type    = coalesce(each.value.compute_type, var.compute_type)
    image           = var.build_image
    type            = "LINUX_CONTAINER"
    privileged_mode = true # docker daemon inside the build

    dynamic "environment_variable" {
      for_each = {
        SERVICE          = each.key
        ECR_REGISTRY     = var.ecr_registry
        ECR_REPOSITORY   = each.value.repository
        DOCKERFILE       = each.value.dockerfile
        CONTEXT_DIR      = each.value.context_dir
        CORE_CONTEXT_DIR = each.value.core_context_dir
        BUILD_MODE       = each.value.mode
        MIRROR_IMAGE     = ""
        OUTPUT_BUCKET    = var.bucket_name
        OUTPUT_PREFIX    = var.output_prefix
        SOURCE_ID        = ""
        BUILD_ARGS       = ""
      }
      content {
        name  = environment_variable.key
        value = environment_variable.value
        type  = "PLAINTEXT"
      }
    }
  }

  source {
    type      = each.value.mode == "mirror" ? "NO_SOURCE" : "S3"
    location  = each.value.mode == "mirror" ? null : "${var.bucket_name}/${var.source_prefix}/${each.key}/source.zip"
    buildspec = file("${path.module}/${each.value.mode == "mirror" ? "buildspec-mirror.yml" : "buildspec-build.yml"}")
  }

  logs_config {
    cloudwatch_logs {
      status     = "ENABLED"
      group_name = aws_cloudwatch_log_group.build[each.key].name
    }
  }
}
