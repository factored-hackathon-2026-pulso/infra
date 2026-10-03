locals {
  push_actions = [
    "ecr:BatchCheckLayerAvailability",
    "ecr:CompleteLayerUpload",
    "ecr:DescribeImages",
    "ecr:InitiateLayerUpload",
    "ecr:PutImage",
    "ecr:UploadLayerPart",
  ]

  publisher_enabled = var.github_oidc_provider_arn != "" && length(var.publish_subjects) > 0

  publisher_assume_policy = {
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["sts:AssumeRoleWithWebIdentity"]
      Principal = {
        Federated = var.github_oidc_provider_arn
      }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = var.publish_subjects
        }
      }
    }]
  }
}

resource "aws_ecr_repository" "this" {
  name                 = var.repository_name
  image_tag_mutability = "IMMUTABLE"
  tags                 = var.tags

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = var.kms_key_arn == "" ? "AES256" : "KMS"
    kms_key         = var.kms_key_arn == "" ? null : var.kms_key_arn
  }
}

resource "aws_ecr_lifecycle_policy" "this" {
  repository = aws_ecr_repository.this.name
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_retention_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Cap the number of stored images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.max_images
        }
        action = { type = "expire" }
      },
    ]
  })
}

resource "aws_iam_role" "publisher" {
  count                = local.publisher_enabled ? 1 : 0
  name_prefix          = "${var.tags["Environment"]}-pulso-image-publisher-"
  assume_role_policy   = jsonencode(local.publisher_assume_policy)
  permissions_boundary = var.least_privilege_policy_boundary == "" ? null : var.least_privilege_policy_boundary
  tags                 = var.tags
}

resource "aws_iam_role_policy" "publisher" {
  count = local.publisher_enabled ? 1 : 0
  name  = "push-to-the-agent-core-repository"
  role  = aws_iam_role.publisher[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "RegistryLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Sid      = "PushToThisRepositoryOnly"
        Effect   = "Allow"
        Action   = local.push_actions
        Resource = [aws_ecr_repository.this.arn]
      },
    ]
  })
}
