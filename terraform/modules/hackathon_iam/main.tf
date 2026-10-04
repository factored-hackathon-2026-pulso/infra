# Instance roles for the three hackathon hosts (ADR 0007): core, platform, engine.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id
  bucket_arn = "arn:${local.partition}:s3:::${var.s3_bucket_name}"

  workloads = {
    core     = { ecr = var.ecr_repository_arns_core, rw = var.core_s3_prefixes, ro = [] }
    platform = { ecr = var.ecr_repository_arns_platform, rw = [], ro = [] }
    engine   = { ecr = var.ecr_repository_arns_engine, rw = var.engine_s3_prefixes, ro = var.engine_lake_read_prefixes }
  }

  statements = {
    for w, c in local.workloads : w => concat(
      [
        {
          Sid      = "EcrToken"
          Effect   = "Allow"
          Action   = ["ecr:GetAuthorizationToken"]
          Resource = "*" # the API does not support resource-level scoping
        },
        {
          Sid      = "ReadParameters"
          Effect   = "Allow"
          Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
          Resource = "arn:${local.partition}:ssm:${var.region}:${local.account_id}:parameter${var.ssm_parameter_path_prefix}/${w}/*"
        },
        {
          Sid      = "WriteLogs"
          Effect   = "Allow"
          Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
          Resource = "arn:${local.partition}:logs:${var.region}:${local.account_id}:log-group:/${var.name}/*:*"
        },
      ],
      length(c.ecr) == 0 ? [] : [
        {
          Sid      = "EcrPull"
          Effect   = "Allow"
          Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
          Resource = c.ecr
        },
      ],
      length(c.rw) + length(c.ro) == 0 ? [] : [
        {
          Sid       = "ListBucket"
          Effect    = "Allow"
          Action    = ["s3:ListBucket"]
          Resource  = local.bucket_arn
          Condition = { StringLike = { "s3:prefix" = [for p in concat(c.rw, c.ro) : "${p}/*"] } }
        },
      ],
      length(c.rw) == 0 ? [] : [
        {
          Sid      = "ObjectReadWrite"
          Effect   = "Allow"
          Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
          Resource = [for p in c.rw : "${local.bucket_arn}/${p}/*"]
        },
      ],
      length(c.ro) == 0 ? [] : [
        {
          Sid      = "ObjectReadOnly"
          Effect   = "Allow"
          Action   = ["s3:GetObject"]
          Resource = [for p in c.ro : "${local.bucket_arn}/${p}/*"]
        },
      ],
    )
  }
}

resource "aws_iam_policy" "boundary" {
  name_prefix = "${var.name}-host-boundary-"
  description = "Permissions boundary: the hosts can never change IAM, Organizations or the account"
  tags        = var.tags
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowWithinIdentityPolicy"
        Effect   = "Allow"
        Action   = "*"
        Resource = "*"
      },
      {
        Sid      = "DenyIdentityAndOrgChanges"
        Effect   = "Deny"
        Action   = ["iam:*", "organizations:*", "account:*"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role" "host" {
  for_each             = local.workloads
  name_prefix          = "${var.name}-${each.key}-"
  permissions_boundary = aws_iam_policy.boundary.arn
  tags                 = merge(var.tags, { Workload = each.key })
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  for_each   = local.workloads
  role       = aws_iam_role.host[each.key].name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_policy" "host" {
  for_each    = local.workloads
  name_prefix = "${var.name}-${each.key}-"
  description = "${each.key} host runtime access"
  tags        = var.tags
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.statements[each.key]
  })
}

resource "aws_iam_role_policy_attachment" "host" {
  for_each   = local.workloads
  role       = aws_iam_role.host[each.key].name
  policy_arn = aws_iam_policy.host[each.key].arn
}

resource "aws_iam_instance_profile" "host" {
  for_each    = local.workloads
  name_prefix = "${var.name}-${each.key}-"
  role        = aws_iam_role.host[each.key].name
  tags        = var.tags
}
