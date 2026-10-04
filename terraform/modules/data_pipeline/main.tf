# The data-pipeline workload (ADR 0006): lake, roles, batch task definition and an optional schedule.
#
# One module composes them because the bucket policy needs the task role's ARN while the task role needs the
# bucket's statements. Terraform resolves that per resource, so there is no cycle, but a single call site keeps the
# wiring in one place. There is no ECS service, no listener and no inbound path: the task runs to completion.

locals {
  name = "data-pipeline"
}

module "lake" {
  source = "../data_lake"

  bucket_name                 = var.lake_bucket_name
  kms_key_arn                 = var.kms_key_arn
  pipeline_task_role_arns     = [module.iam.task_role_arn]
  restricted_reader_role_arns = var.restricted_reader_role_arns
  masked_reader_role_arns     = var.masked_reader_role_arns
  analytics_reader_role_arns  = var.analytics_reader_role_arns
  evaluator_role_arns         = var.evaluator_role_arns
  admin_principal_arns        = var.admin_principal_arns
  publish_retention_days      = var.publish_retention_days
  tags                        = var.tags
}

module "iam" {
  source = "../workload_iam"

  workload_name               = local.name
  aws_region                  = var.aws_region
  own_secret_arns             = [var.pseudonym_key_secret_arn, var.dataset_reader_secret_arn]
  secret_kms_key_arns         = var.secret_kms_key_arns
  task_statements             = module.lake.pipeline_task_statements
  rds_master_secret_arn_guard = var.rds_master_secret_arn_guard
  permissions_boundary        = var.permissions_boundary
  tags                        = var.tags
}

module "task" {
  source = "../workload"

  name               = local.name
  image              = var.image
  command            = var.command
  cluster_arn        = var.cluster_arn
  subnet_ids         = var.subnet_ids
  security_group_ids = var.security_group_ids
  task_role_arn      = module.iam.task_role_arn
  execution_role_arn = module.iam.execution_role_arn
  aws_region         = var.aws_region
  log_group_name     = var.log_group_name
  port               = null
  cpu                = var.cpu
  memory             = var.memory
  create_service     = false

  environment = merge(
    {
      PIPELINE_ROOT      = "s3://${var.lake_bucket_name}"
      WORK_DIR           = "/work"
      AWS_DEFAULT_REGION = var.aws_region
      DATASET_BUCKET     = var.dataset_bucket
      DATASET_PREFIX     = var.dataset_prefix
      DATASET_REGION     = var.dataset_region
    },
    var.kms_key_arn == "" ? {} : { S3_KMS_KEY_ID = var.kms_key_arn },
  )

  # DATASET_AWS_*, never AWS_*: see dataset_reader_secret_arn.
  secrets = {
    PSEUDONYM_KEY                 = var.pseudonym_key_secret_arn
    DATASET_AWS_ACCESS_KEY_ID     = "${var.dataset_reader_secret_arn}:access_key_id::"
    DATASET_AWS_SECRET_ACCESS_KEY = "${var.dataset_reader_secret_arn}:secret_access_key::"
  }

  rds_master_secret_arn_guard = var.rds_master_secret_arn_guard
  tags                        = var.tags
}

module "schedule" {
  count  = var.schedule_expression == null ? 0 : 1
  source = "../scheduled_task"

  name        = local.name
  description = "Runs the data pipeline (ingest_bank, build, publish)."
  cluster_arn = var.cluster_arn
  # The scheduler runs the latest active revision, so it takes the ARN without the ":<revision>" suffix.
  task_definition_arn_without_revision = replace(module.task.task_definition_arn, "/:[0-9]+$/", "")
  task_role_arns                       = [module.iam.task_role_arn, module.iam.execution_role_arn]
  subnet_ids                           = var.subnet_ids
  security_group_ids                   = var.security_group_ids
  schedule_expression                  = var.schedule_expression
  enabled                              = var.schedule_enabled
  # A failed run must not be retried blindly: a retry creates a new run id, but a half-built bronze is cheaper to
  # look at than to repeat three times. The runner is idempotent, so a manual rerun is safe.
  maximum_retry_attempts = 0
  permissions_boundary   = var.permissions_boundary
  tags                   = var.tags
}
