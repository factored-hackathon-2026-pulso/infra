data "aws_iam_policy_document" "github_oidc" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
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
resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.github_oidc_thumbprints
  tags            = var.tags
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
resource "aws_iam_role" "workload" {
  name                 = "${var.name}-workload"
  assume_role_policy   = var.workload_assume_role_policy_json
  permissions_boundary = var.permissions_boundary_arn
  tags                 = var.tags
}
resource "aws_iam_role_policy" "workload" {
  name   = "${var.name}-workload-minimum"
  role   = aws_iam_role.workload.id
  policy = var.workload_policy_json
}
