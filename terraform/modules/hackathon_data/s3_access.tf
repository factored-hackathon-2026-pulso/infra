# Data-class separation for the single bucket (prefix layout in README.md):
#   PII in the clear:  landing/ and lake/bronze/, and data-pipeline's restricted zone (lake/gold_restricted/ and the
#                      published lake/publish/<run>/gold_restricted.duckdb) read by tool-service on the core host
#   everything else:   lake/silver|gold_*, engine/*, core/*, tmp/, logs/
# The bucket policy holds only Deny statements (so it cannot widen access); access is granted by identity policies
# (outputs uploader_policy_json, loader_policy_json, host_policy_json).

locals {
  # An empty principal list would make "not in list" vacuous or invalid; an impossible ARN keeps the Deny active.
  no_principal = "arn:aws:iam::000000000000:role/hackathon-data-no-principal"

  pii_readers = distinct(concat(var.loader_role_arns, var.break_glass_principal_arns, [local.no_principal]))
  pii_writers = distinct(concat(var.loader_role_arns, var.uploader_principal_arns, var.break_glass_principal_arns, [local.no_principal]))
  breakglass  = length(var.break_glass_principal_arns) == 0 ? [local.no_principal] : var.break_glass_principal_arns

  pii_read_resources = ["${local.bucket_arn}/landing/*", "${local.bucket_arn}/lake/bronze/*"]
  restricted_readers = distinct(concat(var.loader_role_arns, var.break_glass_principal_arns, var.restricted_reader_role_arns, [local.no_principal]))
  restricted_read_resources = [
    "${local.bucket_arn}/lake/gold_restricted/*",
    "${local.bucket_arn}/lake/publish/*/gold_restricted.duckdb",
  ]
  pii_write_resources = ["${local.bucket_arn}/landing/*", "${local.bucket_arn}/lake/bronze/*"]

  bucket_policy_statements = concat(
    [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [local.bucket_arn, "${local.bucket_arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "DenyPiiReadToOthers"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource  = local.pii_read_resources
        Condition = { StringNotLike = { "aws:PrincipalArn" = local.pii_readers } }
      },
      {
        Sid       = "DenyRestrictedReadToOthers"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource  = local.restricted_read_resources
        Condition = { StringNotLike = { "aws:PrincipalArn" = local.restricted_readers } }
      },
      {
        Sid       = "DenyPiiWriteToOthers"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion"]
        Resource  = local.pii_write_resources
        Condition = { StringNotLike = { "aws:PrincipalArn" = local.pii_writers } }
      },
    ],
    var.s3_vpc_endpoint_id == "" ? [] : [
      {
        Sid       = "DenyLandingReadOutsideVpce"
        Effect    = "Deny"
        Principal = "*"
        Action    = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource  = ["${local.bucket_arn}/landing/*"]
        Condition = {
          StringNotEquals = { "aws:SourceVpce" = var.s3_vpc_endpoint_id }
          StringNotLike   = { "aws:PrincipalArn" = distinct(concat(local.breakglass, var.loader_role_arns)) }
        }
      },
    ],
  )

  kms_use = ["kms:GenerateDataKey", "kms:Decrypt", "kms:DescribeKey"]

  uploader_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PutLandingOnly"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.bucket_arn}/landing/*"]
      },
      {
        Sid      = "EncryptWithDataKey"
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Encrypt", "kms:Decrypt"] # Decrypt: multipart parts on an SSE-KMS bucket
        Resource = [aws_kms_key.data.arn]
      },
      {
        Sid       = "ListLanding"
        Effect    = "Allow"
        Action    = ["s3:ListBucket"]
        Resource  = [local.bucket_arn]
        Condition = { StringLike = { "s3:prefix" = ["landing/*"] } }
      },
    ]
  })

  loader_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ReadLandingAndLake"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = ["${local.bucket_arn}/landing/*", "${local.bucket_arn}/lake/*"]
      },
      {
        Sid      = "WriteLake"
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
        Resource = ["${local.bucket_arn}/lake/*"]
      },
      {
        Sid      = "ListLandingAndLake"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.bucket_arn]
        Condition = {
          StringLike = { "s3:prefix" = ["landing/*", "lake/*"] }
        }
      },
      {
        Sid      = "UseDataKey"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [aws_kms_key.data.arn]
      },
    ]
  })

  host_policy_json = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadMaskedLakeAndEngine"
        Effect = "Allow"
        Action = ["s3:GetObject"]
        Resource = [
          "${local.bucket_arn}/lake/gold_masked/*",
          "${local.bucket_arn}/lake/gold_analytics/*",
          "${local.bucket_arn}/engine/*",
        ]
      },
      {
        Sid    = "ReadWriteEngineCoreTmp"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject", "s3:AbortMultipartUpload"]
        Resource = [
          "${local.bucket_arn}/engine/*",
          "${local.bucket_arn}/core/*",
          "${local.bucket_arn}/tmp/*",
        ]
      },
      {
        Sid      = "ListNonPiiPrefixes"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = [local.bucket_arn]
        Condition = {
          StringLike = { "s3:prefix" = ["lake/gold_masked/*", "lake/gold_analytics/*", "engine/*", "core/*", "tmp/*"] }
        }
      },
      {
        Sid      = "UseDataKey"
        Effect   = "Allow"
        Action   = local.kms_use
        Resource = [aws_kms_key.data.arn]
      },
    ]
  })
}

resource "aws_s3_bucket_policy" "data" {
  bucket = aws_s3_bucket.data.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.bucket_policy_statements
  })

  depends_on = [aws_s3_bucket_public_access_block.data]
}
