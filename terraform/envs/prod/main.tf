provider "aws" {
  region = var.aws_region
}

locals {
  tags = {
    ManagedBy   = "terraform"
    Service     = "pulso-improvement-engine"
    Environment = "prod"
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
  source                = "../../modules/security"
  vpc_id                = var.vpc_id
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  tags                  = local.tags
}

module "identity" {
  source                          = "../../modules/identity"
  workload_principal              = var.workload_principal
  least_privilege_policy_boundary = var.least_privilege_policy_boundary
  tags                            = local.tags
}

module "compute" {
  source             = "../../modules/compute"
  image_digest       = var.image_digest
  compute_engine     = var.compute_engine
  private_subnet_ids = var.private_subnet_ids
  security_group_ids = var.security_group_ids
  tags               = local.tags
}

module "storage" {
  source               = "../../modules/storage"
  artifact_bucket_name = var.artifact_bucket_name
  source_bucket_name   = var.source_bucket_name
  tags                 = local.tags
}

module "database" {
  source             = "../../modules/database"
  database_engine    = var.database_engine
  private_subnet_ids = var.private_subnet_ids
  tags               = local.tags
}

module "secrets" {
  source             = "../../modules/secrets"
  secret_name_prefix = var.secret_name_prefix
  kms_key_arn        = var.kms_key_arn
  tags               = local.tags
}

module "api" {
  source             = "../../modules/api"
  api_mode           = var.api_mode
  private_subnet_ids = var.private_subnet_ids
  tags               = local.tags
}

module "observability" {
  source           = "../../modules/observability"
  alarm_email      = var.alarm_email
  service_name     = "pulso-improvement-engine"
  metric_namespace = var.metric_namespace
  trace_mode       = var.trace_mode
  tags             = local.tags
}
