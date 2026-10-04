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

# One EC2 per workload; each reads only its own slice of the one secret.
module "compute_core" {
  source                  = "../../modules/hackathon_compute"
  name_prefix             = var.name_prefix
  region                  = var.region
  workload                = "core"
  enabled                 = var.enabled["core"]
  instance_type           = var.instance_types["core"]
  subnet_id               = module.network.private_subnet_ids[0]
  security_group_ids      = [module.network.sg_core_id]
  instance_profile_name   = module.iam.instance_profile_name_core
  private_zone_id         = module.network.zone_id
  data_volume_size_gb     = var.data_volume_size_gb["core"]
  protect_data_volume     = var.protect_data_volume
  enable_cloudwatch_agent = var.enable_cloudwatch_agent
  ssm_prefix              = module.data.ssm_prefix
  bucket_name             = module.data.bucket_name
  secret_arn              = module.data.secret_arn
  kms_key_arn             = module.data.kms_key_arn
  ecr_registry_url        = var.ecr_registry_url
  images                  = var.images.core
  tags                    = local.tags
}

module "compute_platform" {
  source                  = "../../modules/hackathon_compute"
  name_prefix             = var.name_prefix
  region                  = var.region
  workload                = "platform"
  enabled                 = var.enabled["platform"]
  instance_type           = var.instance_types["platform"]
  subnet_id               = module.network.private_subnet_ids[0]
  security_group_ids      = [module.network.sg_platform_id]
  instance_profile_name   = module.iam.instance_profile_name_platform
  private_zone_id         = module.network.zone_id
  data_volume_size_gb     = var.data_volume_size_gb["platform"]
  protect_data_volume     = var.protect_data_volume
  enable_cloudwatch_agent = var.enable_cloudwatch_agent
  ssm_prefix              = module.data.ssm_prefix
  bucket_name             = module.data.bucket_name
  secret_arn              = module.data.secret_arn
  kms_key_arn             = module.data.kms_key_arn
  ecr_registry_url        = var.ecr_registry_url
  images                  = var.images.platform
  tags                    = local.tags
}

module "compute_engine" {
  source                  = "../../modules/hackathon_compute"
  name_prefix             = var.name_prefix
  region                  = var.region
  workload                = "engine"
  enabled                 = var.enabled["engine"]
  instance_type           = var.instance_types["engine"]
  subnet_id               = module.network.private_subnet_ids[0]
  security_group_ids      = [module.network.sg_engine_id]
  instance_profile_name   = module.iam.instance_profile_name_engine
  private_zone_id         = module.network.zone_id
  data_volume_size_gb     = var.data_volume_size_gb["engine"]
  protect_data_volume     = var.protect_data_volume
  enable_cloudwatch_agent = var.enable_cloudwatch_agent
  ssm_prefix              = module.data.ssm_prefix
  bucket_name             = module.data.bucket_name
  secret_arn              = module.data.secret_arn
  kms_key_arn             = module.data.kms_key_arn
  ecr_registry_url        = var.ecr_registry_url
  images                  = var.images.engine
  tags                    = local.tags
}

module "edge" {
  source               = "../../modules/hackathon_edge"
  name_prefix          = var.name_prefix
  vpc_id               = module.network.vpc_id
  private_subnet_ids   = module.network.private_subnet_ids
  platform_instance_id = module.compute_platform.instance_id
  platform_private_ip  = module.compute_platform.private_ip
  engine_instance_id   = module.compute_engine.instance_id
  engine_private_ip    = module.compute_engine.private_ip
}
