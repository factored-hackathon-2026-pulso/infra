output "bucket_name" { value = aws_s3_bucket.lake.bucket }
output "bucket_arn" { value = aws_s3_bucket.lake.arn }

# Exposed so a test can assert on the policy that is attached (the policy is built with jsonencode).
output "bucket_policy_json" { value = jsonencode(local.bucket_policy) }

# Statements for `workload_iam.task_statements`. No kms:, no secretsmanager:, no iam:, no delete: the module
# validation in workload_iam would refuse them anyway. The KMS key policy must name these roles.

# The data-pipeline task: reads bronze/, writes bronze/, bronze_eval/ and publish/. It cannot read bronze_eval/
# or any publication back, and it cannot delete.
output "pipeline_task_statements" {
  value = [
    {
      Sid      = "ListLake"
      Effect   = "Allow"
      Action   = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
      Resource = [local.arn]
    },
    {
      Sid      = "ReadBronze"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["${local.arn}/bronze/*"]
    },
    {
      Sid      = "WriteLake"
      Effect   = "Allow"
      Action   = ["s3:PutObject", "s3:AbortMultipartUpload"]
      Resource = ["${local.arn}/bronze/*", "${local.arn}/bronze_eval/*", "${local.arn}/publish/*"]
    },
  ]
}

# Agent Core runtime read-model tools: personal data in clear.
output "restricted_reader_statements" {
  value = [
    {
      Sid      = "ReadRestrictedPublication"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = concat(local.common_read, ["${local.arn}/publish/*/gold_restricted.duckdb"])
    },
  ]
}

# Consumers of masked per-customer read-models that do not go through Agent Core.
output "masked_reader_statements" {
  value = [
    {
      Sid      = "ReadMaskedPublication"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = concat(local.common_read, ["${local.arn}/publish/*/gold_masked.duckdb"])
    },
  ]
}

# Analysis, ML and dashboards: pseudonymised data only.
output "analytics_reader_statements" {
  value = [
    {
      Sid       = "ListPublications"
      Effect    = "Allow"
      Action    = ["s3:ListBucket"]
      Resource  = [local.arn]
      Condition = { StringLike = { "s3:prefix" = ["publish/*", "publish/"] } }
    },
    {
      Sid      = "ReadAnalyticsPublication"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = concat(local.common_read, ["${local.arn}/publish/*/gold_analytics.duckdb", "${local.arn}/publish/*/parquet/*"])
    },
  ]
}

# The evaluator: only the answers.
output "evaluator_reader_statements" {
  value = [
    {
      Sid       = "ListEvaluatorAnswers"
      Effect    = "Allow"
      Action    = ["s3:ListBucket"]
      Resource  = [local.arn]
      Condition = { StringLike = { "s3:prefix" = ["bronze_eval/*", "bronze_eval/"] } }
    },
    {
      Sid      = "ReadEvaluatorAnswers"
      Effect   = "Allow"
      Action   = ["s3:GetObject"]
      Resource = ["${local.arn}/bronze_eval/*"]
    },
  ]
}
