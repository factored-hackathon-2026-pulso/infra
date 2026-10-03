# Pulso-owned bridge services next to the engine platform: core-runtime (our composed pulso-core-runtime image),
# core-exporter and platform-exporter. Off by default: zero resources until a human opts in. Shared foundations are
# inputs (cluster, VPC, endpoints, Cloud Map namespace) or come from engine_platform; the Core workload slice secrets
# and database are consumed by ARN / security group id.
module "bridge_services" {
  source = "../../modules/bridge_services"

  enabled                             = var.bridge_services_enabled
  core_image                          = var.bridge_core_image
  platform_exporter_image             = var.bridge_platform_exporter_image
  aws_region                          = var.aws_region
  vpc_id                              = module.network.vpc_id
  vpc_cidr                            = var.vpc_cidr
  private_subnet_ids                  = module.network.private_subnet_ids
  cluster_arn                         = module.compute.cluster_arn
  rds_master_secret_arn_guard         = coalesce(module.database.master_user_secret_arn, "arn:aws:secretsmanager:unset:000000000000:secret:rds-master-unset")
  kms_key_arn                         = var.kms_key_arn
  permissions_boundary                = var.least_privilege_policy_boundary
  s3_egress_enabled                   = var.private_endpoints_enabled
  s3_prefix_list_id                   = module.private_endpoints.s3_prefix_list_id
  secret_name_prefix                  = var.secret_name_prefix
  log_retention_days                  = var.log_retention_days
  service_discovery_namespace_id      = module.engine_platform.service_discovery_namespace_id
  control_api_security_group_id       = try(module.engine_platform.security_group_ids["control-api"], "")
  control_api_dns_name                = module.engine_platform.control_api_dns_name == null ? "" : module.engine_platform.control_api_dns_name
  engine_caller_security_group_ids    = var.engine_platform_enabled ? { control-api = module.engine_platform.security_group_ids["control-api"], worker = module.engine_platform.security_group_ids["worker"] } : {}
  core_database_security_group_id     = var.bridge_core_database_security_group_id
  platform_database_security_group_id = var.bridge_platform_database_security_group_id
  manage_core_database_ingress        = var.bridge_manage_core_database_ingress
  manage_platform_database_ingress    = var.bridge_manage_platform_database_ingress
  llm_gateway_url                     = var.bridge_llm_gateway_url
  llm_gateway_security_group_id       = var.bridge_llm_gateway_security_group_id
  core_secret_arns                    = var.bridge_core_secret_arns
  tenant_id                           = var.bridge_tenant_id
  core_instance                       = var.bridge_core_instance
  exporter_binding_ref                = var.bridge_exporter_binding_ref
  expected_runtime_db                 = var.bridge_expected_runtime_db
  expected_eval_db                    = var.bridge_expected_eval_db
  platform_instance                   = var.bridge_platform_instance
  platform_binding_ref                = var.bridge_platform_binding_ref
  runtime_extra_environment           = var.bridge_runtime_extra_environment
  core_runtime_desired_count          = var.bridge_core_runtime_desired_count
  core_exporter_desired_count         = var.bridge_core_exporter_desired_count
  platform_exporter_desired_count     = var.bridge_platform_exporter_desired_count
  tags                                = local.tags
}

check "bridge_services_needs_the_engine_platform_and_private_endpoints" {
  assert {
    condition     = !var.bridge_services_enabled || (var.engine_platform_enabled && var.private_endpoints_enabled)
    error_message = "bridge_services calls control-api (engine_platform) and has no internet egress; enable engine_platform_enabled and private_endpoints_enabled."
  }
}

# bridge_services opens both ends of F1, F2 and F3 itself (security-group references). Setting the engine inputs too
# would declare each rule twice.
check "bridge_services_owns_the_engine_flows" {
  assert {
    condition     = !var.bridge_services_enabled || (length(var.engine_platform_core_runtime_security_group_ids) == 0 && length(var.engine_platform_core_callback_security_group_ids) == 0)
    error_message = "With bridge_services_enabled, leave engine_platform_core_runtime_security_group_ids and engine_platform_core_callback_security_group_ids empty; the module owns those rules. Only engine_platform_core_runtime_url stays manual."
  }
}

# Image repository for the platform exporter (the Core image lives in core_ecr). Shared ecr module only.
module "platform_exporter_ecr" {
  source   = "../../modules/ecr"
  for_each = var.bridge_ecr_enabled ? toset(["pulso-platform-exporter"]) : toset([])

  repository_name = "${local.tags["Environment"]}/${each.key}"
  kms_key_arn     = var.kms_key_arn
  tags            = local.tags
}

output "bridge_services_security_group_ids" {
  description = "core-runtime, core-exporter and platform-exporter security groups; the LLM gateway side must admit core-runtime."
  value       = module.bridge_services.security_group_ids
}

output "bridge_core_runtime_dns_name" {
  description = "Use http://<this>:8000 as engine_platform_core_runtime_url."
  value       = module.bridge_services.core_runtime_dns_name
}

output "bridge_secret_names" {
  description = "Our own secret entries (names only); values are loaded out of band."
  value       = module.bridge_services.secret_names
}

output "bridge_ecr_repository_urls" {
  description = "platform-exporter repository; empty while bridge_ecr_enabled is false."
  value       = { for name, repo in module.platform_exporter_ecr : name => repo.repository_url }
}
