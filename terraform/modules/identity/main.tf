data "aws_iam_policy_document" "github_oidc" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [var.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = var.github_subjects
    }
  }
}
data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}
data "aws_iam_policy_document" "runtime" {
  statement {
    sid       = "ReadRuntimeConfiguration"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.runtime_secret_arn, var.runtime_database_secret_arn]
  }
  statement {
    sid       = "ReadApprovedSourceData"
    actions   = ["s3:GetObject"]
    resources = ["${var.source_bucket_arn}/*"]
  }
  statement {
    sid       = "ReadWriteVersionedArtifacts"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${var.artifact_bucket_arn}/*"]
  }
  # The runtime reads/writes S3 objects with SSE-KMS. It cannot use the CMK
  # directly: AWS KMS must receive the request through S3 in this region.
  statement {
    sid = "UseConfiguredS3DataKey"
    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
    ]
    resources = [var.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.aws_region}.amazonaws.com"]
    }
    # Both buckets enable S3 Bucket Keys. In that mode S3 supplies the bucket
    # ARN, not an object ARN, as the default encryption-context value.
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [var.source_bucket_arn, var.artifact_bucket_arn]
    }
  }
  # Secrets Manager performs the decrypt for GetSecretValue; direct key use is
  # denied by requiring that service path too.
  statement {
    sid       = "UseConfiguredSecretKey"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [var.runtime_secret_arn, var.runtime_database_secret_arn]
    }
  }
}
resource "aws_iam_role" "deploy" {
  name                 = "${var.name}-deploy"
  assume_role_policy   = data.aws_iam_policy_document.github_oidc.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}
resource "aws_iam_role_policy" "deploy" {
  name   = "${var.name}-deploy-minimum"
  role   = aws_iam_role.deploy.id
  policy = var.deploy_policy_json
}
resource "aws_iam_role" "execution" {
  name                 = "${var.name}-execution"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}
resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
resource "aws_iam_role" "runtime" {
  name                 = "${var.name}-runtime"
  assume_role_policy   = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}
resource "aws_iam_role_policy" "runtime" {
  name   = "${var.name}-runtime-minimum"
  role   = aws_iam_role.runtime.id
  policy = data.aws_iam_policy_document.runtime.json

  lifecycle {
    precondition {
      condition     = var.runtime_database_secret_arn != var.rds_master_secret_arn_guard
      error_message = "runtime_database_secret_arn must not equal the RDS master secret."
    }
  }
}
