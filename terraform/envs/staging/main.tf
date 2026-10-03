provider "aws" {
  region = var.aws_region
}

locals {
  tags = {
    ManagedBy   = "terraform"
    Service     = "pulso-improvement-engine"
    Environment = "staging"
  }
}

module "network" {
  source               = "../../modules/network"
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  nat_strategy         = var.nat_strategy
  tags                 = local.tags
}

module "security" {
  source = "../../modules/security"
  vpc_id = module.network.vpc_id
  tags   = local.tags
}

module "identity" {
  source                              = "../../modules/identity"
  least_privilege_policy_boundary     = var.least_privilege_policy_boundary
  artifact_bucket_arn                 = module.storage.artifact_bucket_arn
  source_bucket_arn                   = module.storage.source_bucket_arn
  runtime_secret_arn                  = module.secrets.runtime_secret_arn
  runtime_secret_kms_key_arn          = var.kms_key_arn
  runtime_database_secret_arn         = var.runtime_database_secret_arn
  runtime_database_secret_kms_key_arn = var.kms_key_arn
  rds_master_secret_arn_guard         = module.database.master_user_secret_arn
  aws_region                          = var.aws_region
  tags                                = local.tags
}

module "compute" {
  source                      = "../../modules/compute"
  image_digest                = var.image_digest
  private_subnet_ids          = module.network.private_subnet_ids
  security_group_ids          = [module.security.runtime_security_group_id]
  task_role_arn               = module.identity.task_role_arn
  execution_role_arn          = module.identity.execution_role_arn
  aws_region                  = var.aws_region
  desired_count               = var.desired_count
  runtime_secret_arn          = module.secrets.runtime_secret_arn
  database_endpoint           = module.database.endpoint
  runtime_database_secret_arn = var.runtime_database_secret_arn
  rds_master_secret_arn_guard = module.database.master_user_secret_arn
  log_group_name              = module.observability.log_group_name
  tags                        = local.tags
}

module "storage" {
  source               = "../../modules/storage"
  artifact_bucket_name = var.artifact_bucket_name
  source_bucket_name   = var.source_bucket_name
  tags                 = local.tags
}

module "database" {
  source                = "../../modules/database"
  database_engine       = var.database_engine
  private_subnet_ids    = module.network.private_subnet_ids
  security_group_ids    = [module.security.database_security_group_id]
  instance_class        = var.database_instance_class
  backup_retention_days = var.database_backup_retention_days
  deletion_protection   = var.database_deletion_protection
  skip_final_snapshot   = var.database_skip_final_snapshot
  multi_az              = var.database_multi_az
  kms_key_arn           = var.kms_key_arn
  tags                  = local.tags
}

module "secrets" {
  source             = "../../modules/secrets"
  secret_name_prefix = var.secret_name_prefix
  kms_key_arn        = var.kms_key_arn
  tags               = local.tags
}

module "observability" {
  source             = "../../modules/observability"
  service_name       = "improvement-engine"
  log_retention_days = var.log_retention_days
  alarm_actions      = var.alarm_actions
  cluster_name       = "staging-pulso"
  tags               = local.tags
}

module "agent_core_image_registry" {
  count                           = var.agent_core_repository_name == "" ? 0 : 1
  source                          = "../../modules/image_registry"
  repository_name                 = var.agent_core_repository_name
  kms_key_arn                     = ""
  github_oidc_provider_arn        = var.agent_core_publisher_oidc_provider_arn
  publish_subjects                = var.agent_core_publish_subjects
  least_privilege_policy_boundary = var.least_privilege_policy_boundary
  untagged_retention_days         = 14
  max_images                      = 100
  tags                            = merge(local.tags, { Service = "pulso-agent-core" })
}

check "private_compute_requires_nat" {
  assert {
    condition     = var.desired_count == 0 || var.nat_strategy != "none"
    error_message = "desired_count > 0 requires NAT in v1; VPC endpoints are not yet implemented."
  }
}
