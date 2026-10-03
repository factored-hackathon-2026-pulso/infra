# Shared AWS-API VPC endpoints (ECR, Secrets Manager, Logs, KMS, S3). Off by default: zero resources until a human
# opts in. Private workloads without internet egress (engine_platform, Core exporter/migrate/sweep) need them.
module "private_endpoints" {
  source = "../../modules/core_vpc_endpoints"

  enabled             = var.private_endpoints_enabled
  aws_region          = var.aws_region
  vpc_id              = module.network.vpc_id
  vpc_cidr            = var.vpc_cidr
  subnet_ids          = module.network.private_subnet_ids
  route_table_ids     = module.network.private_route_table_ids
  customer_kms_in_use = var.kms_key_arn != ""
  ecs_api             = var.engine_platform_enabled
  tags                = local.tags
}

# Improvement-engine platform workloads (control-api, worker, migrate, sandbox-lab). Off by default; the existing
# single "improvement-engine" service in module.compute is untouched.
module "engine_platform" {
  source = "../../modules/engine_platform"

  enabled                          = var.engine_platform_enabled
  image                            = var.engine_platform_image
  sandbox_image                    = var.engine_platform_sandbox_image
  aws_region                       = var.aws_region
  vpc_id                           = module.network.vpc_id
  vpc_cidr                         = var.vpc_cidr
  private_subnet_ids               = module.network.private_subnet_ids
  cluster_arn                      = module.compute.cluster_arn
  database_security_group_id       = module.security.database_security_group_id
  rds_master_secret_arn_guard      = coalesce(module.database.master_user_secret_arn, "arn:aws:secretsmanager:unset:000000000000:secret:rds-master-unset")
  s3_egress_enabled                = var.private_endpoints_enabled
  s3_prefix_list_id                = module.private_endpoints.s3_prefix_list_id
  kms_key_arn                      = var.kms_key_arn
  permissions_boundary             = var.least_privilege_policy_boundary
  secret_name_prefix               = var.secret_name_prefix
  log_retention_days               = var.log_retention_days
  core_runtime_url                 = var.engine_platform_core_runtime_url
  core_runtime_security_group_ids  = var.engine_platform_core_runtime_security_group_ids
  core_callback_security_group_ids = var.engine_platform_core_callback_security_group_ids
  service_discovery_namespace_id   = var.engine_platform_service_discovery_namespace_id
  alarm_actions                    = var.alarm_actions
  tags                             = local.tags
}

check "engine_platform_requires_private_endpoints" {
  assert {
    condition     = !var.engine_platform_enabled || var.private_endpoints_enabled
    error_message = "engine_platform workloads have no internet egress; enable private_endpoints_enabled so they can pull images, read secrets and write logs."
  }
}
