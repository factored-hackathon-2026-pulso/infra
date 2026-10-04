provider "aws" {
  region = var.region
}

locals {
  tags = {
    ManagedBy   = "terraform"
    Service     = "pulso-hackathon"
    Environment = "hackathon"
  }
}

module "network" {
  source      = "../../modules/hackathon_network"
  name_prefix = var.name_prefix
  region      = var.region
}

module "data" {
  source        = "../../modules/hackathon_data"
  name_prefix   = var.name_prefix
  region        = var.region
  vpc_id        = module.network.vpc_id
  db_subnet_ids = module.network.db_subnet_ids
  sg_db_id      = module.network.sg_db_id
}

module "iam" {
  source                   = "../../modules/hackathon_iam"
  name_prefix              = var.name_prefix
  bucket_arn               = module.data.bucket_arn
  ssm_parameter_arn_prefix = module.data.ssm_parameter_arn_prefix
  secret_arn               = module.data.secret_arn
  kms_key_arn              = module.data.kms_key_arn
}

module "compute" {
  source                  = "../../modules/hackathon_compute"
  name_prefix             = var.name_prefix
  region                  = var.region
  enabled                 = var.enabled
  instance_type           = var.instance_type
  subnet_id               = module.network.private_subnet_ids[0]
  security_group_ids      = [module.network.sg_host_id]
  instance_profile_name   = module.iam.instance_profile_name
  data_volume_size_gb     = var.data_volume_size_gb
  protect_data_volume     = var.protect_data_volume
  enable_cloudwatch_agent = var.enable_cloudwatch_agent
  ssm_prefix              = module.data.ssm_prefix
  bucket_name             = module.data.bucket_name
  secret_arn              = module.data.secret_arn
  kms_key_arn             = module.data.kms_key_arn
  ecr_registry_url        = var.ecr_registry_url
  images                  = var.images
  tags                    = local.tags
}

module "edge" {
  source             = "../../modules/hackathon_edge"
  name_prefix        = var.name_prefix
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids
  origin_instance_id = module.compute.instance_id
  origin_private_ip  = module.compute.private_ip
  origin_private_dns = module.compute.private_dns
}
