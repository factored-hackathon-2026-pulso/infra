data "aws_iam_policy_document" "task_assume" {
  statement { actions = ["sts:AssumeRole"]; principals { type = "Service"; identifiers = ["ecs-tasks.amazonaws.com"] } }
}
locals {
  task_policy = {
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = ["s3:GetObject"], Resource = ["${var.source_bucket_arn}/*"] },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = ["${var.artifact_bucket_arn}/*"] },
    ]
  }

  execution_secret_policy = {
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ReadRuntimeSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = [var.runtime_secret_arn]
      }],
      var.runtime_secret_kms_key_arn == "" ? [] : [{
        Sid      = "DecryptRuntimeSecret"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = [var.runtime_secret_kms_key_arn]
        Condition = {
          StringEquals = {
            "kms:ViaService"                    = "secretsmanager.${var.aws_region}.amazonaws.com"
            "kms:EncryptionContext:SecretARN"   = var.runtime_secret_arn
          }
        }
      }],
    )
  }
}
resource "aws_iam_role" "task" { name_prefix = "${var.tags["Environment"]}-pulso-task-"; assume_role_policy = data.aws_iam_policy_document.task_assume.json; permissions_boundary = var.least_privilege_policy_boundary == "" ? null : var.least_privilege_policy_boundary; tags = var.tags }
resource "aws_iam_role" "execution" { name_prefix = "${var.tags["Environment"]}-pulso-exec-"; assume_role_policy = data.aws_iam_policy_document.task_assume.json; permissions_boundary = var.least_privilege_policy_boundary == "" ? null : var.least_privilege_policy_boundary; tags = var.tags }
resource "aws_iam_role_policy_attachment" "execution" { role = aws_iam_role.execution.name; policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" }
resource "aws_iam_role_policy" "task" { name = "pulso-runtime-data"; role = aws_iam_role.task.id; policy = jsonencode(local.task_policy) }

# ECS resolves task-definition secret references before the container starts.
# This permission therefore belongs to the execution role, not the task role.
resource "aws_iam_role_policy" "execution_secret" {
  name   = "pulso-runtime-secret-resolution"
  role   = aws_iam_role.execution.id
  policy = jsonencode(local.execution_secret_policy)
}
