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
  private_subnet_cidrs = var.private_subnet_cidrs
  tags                 = local.tags
}

module "data" {
  source               = "../../modules/data"
  artifact_bucket_name = var.artifact_bucket_name
  source_bucket_name   = var.source_bucket_name
  tags                 = local.tags
}

module "identity" {
  source            = "../../modules/identity"
  github_repository = var.github_repository
  environment_name  = "staging"
  tags              = local.tags
}

module "compute" {
  source             = "../../modules/compute"
  image_digest       = var.image_digest
  private_subnet_ids = var.private_subnet_ids
  security_group_ids = var.security_group_ids
  tags               = local.tags
}

module "observability" {
  source       = "../../modules/observability"
  alarm_email  = var.alarm_email
  service_name = "pulso-improvement-engine"
  tags         = local.tags
}
