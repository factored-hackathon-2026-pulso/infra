data "aws_iam_policy_document" "task_assume" {
  statement { actions = ["sts:AssumeRole"]; principals { type = "Service"; identifiers = ["ecs-tasks.amazonaws.com"] } }
}
resource "aws_iam_role" "task" { name_prefix = "${var.tags["Environment"]}-pulso-task-"; assume_role_policy = data.aws_iam_policy_document.task_assume.json; permissions_boundary = var.least_privilege_policy_boundary == "" ? null : var.least_privilege_policy_boundary; tags = var.tags }
resource "aws_iam_role" "execution" { name_prefix = "${var.tags["Environment"]}-pulso-exec-"; assume_role_policy = data.aws_iam_policy_document.task_assume.json; permissions_boundary = var.least_privilege_policy_boundary == "" ? null : var.least_privilege_policy_boundary; tags = var.tags }
resource "aws_iam_role_policy_attachment" "execution" { role = aws_iam_role.execution.name; policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy" }
resource "aws_iam_role_policy" "task" { name = "pulso-runtime-data"; role = aws_iam_role.task.id; policy = jsonencode({ Version = "2012-10-17", Statement = [{ Effect = "Allow", Action = ["s3:GetObject"], Resource = ["${var.source_bucket_arn}/*"] }, { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject"], Resource = ["${var.artifact_bucket_arn}/*"] }] }) }

# ECS resolves task-definition secret references before the container starts.
# This permission therefore belongs to the execution role, not the task role.
data "aws_iam_policy_document" "execution_secret" {
  statement {
    sid       = "ReadRuntimeSecret"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.runtime_secret_arn]
  }

  dynamic "statement" {
    for_each = var.runtime_secret_kms_key_arn == "" ? [] : [var.runtime_secret_kms_key_arn]
    content {
      sid       = "DecryptRuntimeSecret"
      actions   = ["kms:Decrypt"]
      resources = [statement.value]

      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
      }

      condition {
        test     = "StringEquals"
        variable = "kms:EncryptionContext:SecretARN"
        values   = [var.runtime_secret_arn]
      }
    }
  }
}

resource "aws_iam_role_policy" "execution_secret" {
  name   = "pulso-runtime-secret-resolution"
  role   = aws_iam_role.execution.id
  policy = data.aws_iam_policy_document.execution_secret.json
}
