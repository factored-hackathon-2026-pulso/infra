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
  log_retention_days          = var.log_retention_days
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
  service_name       = module.compute.service_name
  log_retention_days = var.log_retention_days
  alarm_actions      = var.alarm_actions
  cluster_name       = "staging-pulso"
  tags               = local.tags
}

check "private_compute_requires_nat" {
  assert {
    condition     = var.desired_count == 0 || var.nat_strategy != "none"
    error_message = "desired_count > 0 requires NAT in v1; VPC endpoints are not yet implemented."
  }
}

# --- Agent Core workload (ADR 0003, ADR 0005) -------------------------------------------------------------------
# Own network path, database, proxy, secrets, roles and ECR repository; it shares only the VPC, the ECS cluster
# and the alarm destination with the improvement engine.

module "agent_core_network" {
  source        = "../../modules/agent_core_network"
  vpc_id        = module.network.vpc_id
  ingress_cidrs = var.agent_core_ingress_cidrs
  tags          = local.tags
}

module "agent_core_ecr" {
  source          = "../../modules/ecr"
  repository_name = "${local.tags["Environment"]}/agent-core"
  kms_key_arn     = var.kms_key_arn
  tags            = local.tags
}

module "agent_core_database" {
  source                = "../../modules/database"
  database_engine       = var.database_engine
  private_subnet_ids    = module.network.private_subnet_ids
  security_group_ids    = [module.agent_core_network.database_security_group_id]
  instance_class        = var.database_instance_class
  backup_retention_days = var.database_backup_retention_days
  deletion_protection   = var.database_deletion_protection
  skip_final_snapshot   = var.database_skip_final_snapshot
  multi_az              = var.database_multi_az
  kms_key_arn           = var.kms_key_arn
  tags                  = local.tags
}

module "agent_core_proxy" {
  source                      = "../../modules/rds_proxy"
  aws_region                  = var.aws_region
  db_instance_identifier      = module.agent_core_database.identifier
  private_subnet_ids          = module.network.private_subnet_ids
  security_group_ids          = [module.agent_core_network.proxy_security_group_id]
  application_secret_arn      = var.agent_core_database_secret_arn
  rds_master_secret_arn_guard = module.agent_core_database.master_user_secret_arn
  secret_kms_key_arn          = var.kms_key_arn
  tags                        = local.tags
}

module "agent_core_data" {
  source           = "../../modules/agent_core_data"
  name_prefix      = "${local.tags["Environment"]}-agent-core"
  blob_bucket_name = var.agent_core_blob_bucket_name
  kms_key_arn      = var.kms_key_arn
  consumers        = var.agent_core_event_consumers
  alarm_actions    = var.alarm_actions
  tags             = local.tags
}

module "agent_core_ingress" {
  source             = "../../modules/agent_core_ingress"
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  security_group_id  = module.agent_core_network.alb_security_group_id
  certificate_arn    = var.agent_core_certificate_arn
  tags               = local.tags
}

module "agent_core_workload" {
  source = "../../modules/agent_core_workload"

  aws_region               = var.aws_region
  image                    = var.agent_core_image
  cluster_arn              = module.compute.cluster_arn
  cluster_name             = "${local.tags["Environment"]}-pulso"
  private_subnet_ids       = module.network.private_subnet_ids
  security_group_ids       = [module.agent_core_network.service_security_group_id]
  target_group_arn         = module.agent_core_ingress.target_group_arn
  target_group_arn_suffix  = module.agent_core_ingress.target_group_arn_suffix
  load_balancer_arn_suffix = module.agent_core_ingress.load_balancer_arn_suffix
  blob_bucket_name         = module.agent_core_data.blob_bucket_name
  blob_bucket_arn          = module.agent_core_data.blob_bucket_arn
  blob_kms_key_arn         = var.kms_key_arn
  events_topic_arn         = module.agent_core_data.events_topic_arn
  secrets_kms_key_arn      = var.kms_key_arn
  secret_name_prefix       = "${var.secret_name_prefix}/agent-core"
  extra_secret_names       = var.agent_core_extra_secret_names
  permissions_boundary     = var.least_privilege_policy_boundary
  serve_agents             = var.agent_core_serve_agents
  allow_demo               = var.agent_core_allow_demo
  serve_desired_count      = var.agent_core_desired_count
  serve_min_count          = var.agent_core_min_count
  serve_max_count          = var.agent_core_max_count
  log_retention_days       = var.log_retention_days
  otel_environment         = var.agent_core_otel_environment
  tags                     = local.tags
}

module "agent_core_observability" {
  source                   = "../../modules/agent_core_observability"
  name_prefix              = "${local.tags["Environment"]}-agent-core"
  cluster_name             = "${local.tags["Environment"]}-pulso"
  service_name             = module.agent_core_workload.service_name
  relay_service_name       = module.agent_core_workload.relay_service_name
  log_group_name           = module.agent_core_workload.log_group_name
  load_balancer_arn_suffix = module.agent_core_ingress.load_balancer_arn_suffix
  target_group_arn_suffix  = module.agent_core_ingress.target_group_arn_suffix
  alarm_actions            = var.alarm_actions
  tags                     = local.tags
}

check "agent_core_private_compute_requires_nat" {
  assert {
    condition     = var.agent_core_desired_count == 0 || var.nat_strategy != "none"
    error_message = "agent_core_desired_count > 0 requires NAT: the LLM, JEV and AWS APIs are reached over HTTPS (ADR 0003 item 6)."
  }
}
