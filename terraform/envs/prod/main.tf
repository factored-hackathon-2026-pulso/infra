provider "aws" {
  region = var.aws_region
}
locals {
  name = "pulso-prod-demo"
  tags = {
    ManagedBy = "terraform", Service = "pulso-improvement-engine", Environment = "prod", Purpose = "hackathon-demo"
  }
}
module "network" {
  source               = "../../modules/network"
  name                 = local.name
  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs
  availability_zones   = var.availability_zones
  nat_strategy         = var.nat_strategy
  tags                 = local.tags
}
module "security" {
  source                = "../../modules/security"
  name                  = local.name
  vpc_id                = module.network.vpc_id
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  container_port        = var.container_port
  tags                  = local.tags
}
module "identity" {
  source                           = "../../modules/identity"
  name                             = local.name
  github_oidc_thumbprints          = var.github_oidc_thumbprints
  github_subjects                  = var.github_subjects
  permissions_boundary_arn         = var.permissions_boundary_arn
  deploy_policy_json               = var.deploy_policy_json
  workload_assume_role_policy_json = var.workload_assume_role_policy_json
  workload_policy_json             = var.workload_policy_json
  tags                             = local.tags
}
module "storage" {
  source               = "../../modules/storage"
  artifact_bucket_name = var.artifact_bucket_name
  source_bucket_name   = var.source_bucket_name
  kms_key_arn          = var.kms_key_arn
  tags                 = local.tags
}
module "database" {
  source                     = "../../modules/database"
  name                       = local.name
  private_subnet_ids         = module.network.private_subnet_ids
  database_security_group_id = module.security.database_security_group_id
  postgres_engine_version    = var.postgres_engine_version
  instance_class             = var.db_instance_class
  allocated_storage_gib      = var.allocated_storage_gib
  max_allocated_storage_gib  = var.max_allocated_storage_gib
  backup_retention_days      = var.backup_retention_days
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot
  multi_az                   = var.multi_az
  tags                       = local.tags
}
module "compute" {
  source             = "../../modules/compute"
  name               = local.name
  aws_region         = var.aws_region
  image_digest       = var.image_digest
  private_subnet_ids = module.network.private_subnet_ids
  security_group_ids = [module.security.workload_security_group_id]
  execution_role_arn = module.identity.workload_role_arn
  task_role_arn      = module.identity.workload_role_arn
  container_port     = var.container_port
  task_cpu           = var.task_cpu
  task_memory        = var.task_memory
  desired_count      = var.desired_count
  log_retention_days = var.log_retention_days
  tags               = local.tags
}
module "observability" {
  source                 = "../../modules/observability"
  name                   = local.name
  service_name           = module.compute.service_name
  cluster_name           = module.compute.cluster_name
  db_instance_identifier = module.database.identifier
  alarm_email            = var.alarm_email
  cpu_alarm_threshold    = var.cpu_alarm_threshold
  log_retention_days     = var.log_retention_days
  tags                   = local.tags
}
module "api" {
  source               = "../../modules/api"
  name                 = local.name
  access_log_group_arn = module.observability.api_log_group_arn
  tags                 = local.tags
}
module "secrets" {
  source               = "../../modules/secrets"
  secret_name_prefix   = "/pulso/prod"
  kms_key_arn          = var.kms_key_arn
  recovery_window_days = var.secret_recovery_window_days
  tags                 = local.tags
}
