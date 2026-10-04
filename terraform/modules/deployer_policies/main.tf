# Least-privilege identity policy documents for the people or CI jobs that ship a change to ONE workload without a
# full infra apply: build an image, push it, record its digest in SSM and run the deploy document on that host.
# This module creates no IAM resource: the human attaches an output to the IAM users or roles he creates for a team.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  bucket_arn = "arn:${local.partition}:s3:::${var.bucket_name}"
  ssm_arn    = "arn:${local.partition}:ssm:${var.region}:${local.account_id}"

  policies = {
    for w, c in var.workloads : w => {
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
            Sid    = "EcrPushPull"
            Effect = "Allow"
            Action = [
              "ecr:BatchCheckLayerAvailability",
              "ecr:BatchGetImage",
              "ecr:CompleteLayerUpload",
              "ecr:DescribeImages",
              "ecr:GetDownloadUrlForLayer",
              "ecr:InitiateLayerUpload",
              "ecr:PutImage",
              "ecr:UploadLayerPart",
            ]
            Resource = [for r in c.repositories : "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${r}"]
          },
          {
            Sid      = "WriteImageParameters"
            Effect   = "Allow"
            Action   = "ssm:PutParameter"
            Resource = [for k in c.image_keys : "${local.ssm_arn}:parameter${var.ssm_prefix}/${w}/images/${k}"]
          },
          {
            Sid      = "ReadImageParameters"
            Effect   = "Allow"
            Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParameterHistory"]
            Resource = [for k in c.image_keys : "${local.ssm_arn}:parameter${var.ssm_prefix}/${w}/images/${k}"]
          },
          {
            Sid      = "SendDeployDocument"
            Effect   = "Allow"
            Action   = "ssm:SendCommand"
            Resource = "${local.ssm_arn}:document/${var.document_name_prefix}-${w}"
          },
          {
            Sid      = "SendDeployInstance"
            Effect   = "Allow"
            Action   = "ssm:SendCommand"
            Resource = "arn:${local.partition}:ec2:${var.region}:${local.account_id}:instance/*"
            Condition = {
              StringEquals = { "ssm:resourceTag/${var.instance_tag_key}" = w }
            }
          },
          {
            Sid      = "ReadCommandResult"
            Effect   = "Allow"
            Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
            Resource = "*" # the API does not support resource-level scoping
          },
          {
            Sid      = "PutBuildSource"
            Effect   = "Allow"
            Action   = "s3:PutObject"
            Resource = [for s in c.build_services : "${local.bucket_arn}/${var.source_prefix}/${s}/*"]
          },
          {
            Sid      = "GetBuildOutput"
            Effect   = "Allow"
            Action   = "s3:GetObject"
            Resource = [for s in c.build_services : "${local.bucket_arn}/${var.output_prefix}/${s}/*"]
          },
          {
            Sid       = "ListBuildOutput"
            Effect    = "Allow"
            Action    = "s3:ListBucket"
            Resource  = local.bucket_arn
            Condition = { StringLike = { "s3:prefix" = [for s in c.build_services : "${var.output_prefix}/${s}/*"] } }
          },
          {
            Sid      = "UseDataKey"
            Effect   = "Allow"
            Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
            Resource = var.kms_key_arn
          },
        ],
        length([for s in c.build_services : s if contains(keys(var.project_arns), s)]) == 0 ? [] : [
          {
            Sid      = "Build"
            Effect   = "Allow"
            Action   = ["codebuild:StartBuild", "codebuild:BatchGetBuilds"]
            Resource = [for s in c.build_services : var.project_arns[s] if contains(keys(var.project_arns), s)]
          },
        ],
      )
    }
  }
}
