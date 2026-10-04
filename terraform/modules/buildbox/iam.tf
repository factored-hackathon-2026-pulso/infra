locals {
  bucket_arn   = "arn:${local.partition}:s3:::${local.bucket}"
  instance_arn = "arn:${local.partition}:ec2:${var.region}:${local.account_id}:instance/${aws_instance.this.id}"
  document_arn = "arn:${local.partition}:ssm:${var.region}::document/AWS-RunShellScript"

  user_policy = {
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "BucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.bucket_arn]
      },
      {
        Sid      = "BucketObjects"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${local.bucket_arn}/*"]
      },
      {
        Sid      = "RunCommandOnlyOnThisBox"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = [local.document_arn, local.instance_arn]
      },
      {
        # These read-only actions do not support resource-level permissions.
        Sid      = "ReadOnlyNoResourceLevel"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:DescribeInstanceInformation", "ec2:DescribeInstances", "tag:GetResources"]
        Resource = ["*"]
      },
      {
        Sid      = "StartStopOnlyThisBox"
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = [local.instance_arn]
        Condition = {
          StringEquals = { "aws:ResourceTag/Purpose" = "buildbox" }
        }
      },
    ]
  }
}

resource "aws_iam_user" "this" {
  name          = var.user_name
  force_destroy = true # lets terraform destroy remove a console-created access key
  tags          = local.tags
}

# No aws_iam_access_key on purpose: the human creates the key in the console.
resource "aws_iam_user_policy" "this" {
  name   = "buildbox-scoped"
  user   = aws_iam_user.this.name
  policy = jsonencode(local.user_policy)
}

resource "aws_iam_role" "this" {
  name_prefix = "pulso-buildbox-"
  tags        = local.tags

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "s3" {
  name = "buildbox-bucket"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.bucket_arn]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = ["${local.bucket_arn}/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["s3:DeleteObject"]
        Resource = ["${local.bucket_arn}/state/*"]
      },
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name_prefix = "pulso-buildbox-"
  role        = aws_iam_role.this.name
  tags        = local.tags
}


