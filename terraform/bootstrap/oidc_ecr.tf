locals {
  oidc_enabled = var.github_org != "" && var.github_repo != ""
  ecr_names    = { for n in var.ecr_repositories : n => "${var.ecr_repository_prefix}/${n}" }
}

# Reuses the shared ecr module (immutable tags, scan on push, lifecycle).
module "ecr" {
  source   = "../modules/ecr"
  for_each = local.ecr_names

  repository_name = each.value
  tags            = var.tags
}

resource "aws_iam_openid_connect_provider" "github" {
  count          = local.oidc_enabled ? 1 : 0
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
  tags           = var.tags
}

# Plan/push role for the infra repo CI. Deliberately NOT an apply role: applies are run by a human via SSO after
# reviewing a saved plan (docs/runbook-new-account.md).
resource "aws_iam_role" "deploy" {
  count = local.oidc_enabled ? 1 : 0
  name  = "pulso-infra-ci"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github[0].arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          "token.actions.githubusercontent.com:sub" = [for r in var.github_allowed_refs : "repo:${var.github_org}/${var.github_repo}:ref:${r}"]
        }
      }
    }]
  })
  max_session_duration = 3600
  tags                 = var.tags
}

# Read-only so `terraform plan` can refresh; the only writes are the two scoped policies below.
resource "aws_iam_role_policy_attachment" "readonly" {
  count      = local.oidc_enabled ? 1 : 0
  role       = aws_iam_role.deploy[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "state" {
  count = local.oidc_enabled ? 1 : 0
  name  = "state-bucket"
  role  = aws_iam_role.deploy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = aws_s3_bucket.state.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "${aws_s3_bucket.state.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy" "ecr_push" {
  count = local.oidc_enabled ? 1 : 0
  name  = "ecr-push"
  role  = aws_iam_role.deploy[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*" # the API does not support resource-level scoping for this single action
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer",
        ]
        Resource = [for r in module.ecr : r.repository_arn]
      },
    ]
  })
}
