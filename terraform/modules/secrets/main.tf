resource "aws_secretsmanager_secret" "runtime" {
  name                    = "${var.secret_name_prefix}/runtime"
  kms_key_id              = var.kms_key_arn
  recovery_window_in_days = var.recovery_window_days
  tags                    = var.tags
}
