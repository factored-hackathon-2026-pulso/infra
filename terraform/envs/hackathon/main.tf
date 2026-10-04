provider "aws" {
  region = var.region
}

# CloudFront-scope WAF web ACLs exist only in us-east-1, whatever the main region is.
provider "aws" {
  alias  = "us_east_1"
  region = var.cloudfront_waf_region
}

data "aws_caller_identity" "current" {}

locals {
  tags = {
    ManagedBy   = "terraform"
    Service     = "pulso-hackathon"
    Environment = var.environment
  }

  account_id = data.aws_caller_identity.current.account_id

  ecr_registry_url = coalesce(var.ecr_registry_url, "${local.account_id}.dkr.ecr.${var.region}.amazonaws.com")

  # Defaults for a single-account prod: the IAM users and the root of THIS account (roles, i.e. the hosts, never
  # match "user/*"; the bucket policy stays deny-only and identity policies still have to allow the call).
  account_principals  = ["arn:aws:iam::${local.account_id}:user/*", "arn:aws:iam::${local.account_id}:root"]
  uploader_principals = length(var.uploader_principal_arns) > 0 ? var.uploader_principal_arns : local.account_principals
  break_glass         = length(var.break_glass_principal_arns) > 0 ? var.break_glass_principal_arns : local.account_principals
  loader_roles        = var.engine_host_can_load ? distinct(concat(var.loader_role_arns, [module.iam.instance_role_arn_engine])) : var.loader_role_arns

  # ECR repositories per host, derived from the digest-pinned image references (repo@sha256:...).
  ecr_arns = {
    for w, imgs in var.images : w => distinct([
      for v in values(imgs) : "arn:aws:ecr:${var.region}:${data.aws_caller_identity.current.account_id}:repository/${join("/", slice(split("/", split("@", v)[0]), 1, length(split("/", split("@", v)[0]))))}"
    ])
  }
}

module "network" {
  source = "../../modules/hackathon_network"
  name   = var.name_prefix
  region = var.region
  tags   = local.tags
}

module "data" {
  source        = "../../modules/hackathon_data"
  name_prefix   = var.name_prefix
  region        = var.region
  vpc_id        = module.network.vpc_id
  db_subnet_ids = module.network.db_subnet_ids
  sg_db_id      = module.network.sg_db_id

  # Deny-only bucket policy: the reads of landing/ are bound to the S3 gateway endpoint of this VPC.
  db_deletion_protection     = var.db_deletion_protection
  db_skip_final_snapshot     = var.db_skip_final_snapshot
  s3_vpc_endpoint_id         = module.network.s3_gateway_endpoint_id
  loader_role_arns           = local.loader_roles
  uploader_principal_arns    = local.uploader_principals
  break_glass_principal_arns = local.break_glass
  tags                       = local.tags
}

module "iam" {
  source                    = "../../modules/hackathon_iam"
  name                      = var.name_prefix
  region                    = var.region
  ssm_parameter_path_prefix = module.data.ssm_prefix
  s3_bucket_name            = module.data.bucket_name
  secret_arn                = module.data.secret_arn
  kms_key_arn               = module.data.kms_key_arn

  # Engine host: loader by default (engine_host_can_load); otherwise only the masked and analytics zones.
  # Core and platform never read landing/ or lake/bronze/ (the bucket policy denies them).
  engine_can_load           = var.engine_host_can_load
  engine_lake_read_prefixes = ["lake/gold_masked", "lake/gold_analytics"]

  ecr_repository_arns_core     = local.ecr_arns.core
  ecr_repository_arns_platform = local.ecr_arns.platform
  ecr_repository_arns_engine   = local.ecr_arns.engine
  tags                         = local.tags
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
  ecr_registry_url        = local.ecr_registry_url
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
  ecr_registry_url        = local.ecr_registry_url
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
  ecr_registry_url        = local.ecr_registry_url
  images                  = var.images.engine
  tags                    = local.tags
}

module "edge" {
  source = "../../modules/hackathon_edge"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name                 = var.name_prefix
  platform_origin_arn  = module.compute_platform.instance_arn
  platform_origin_host = module.compute_platform.private_dns
  engine_origin_arn    = module.compute_engine.instance_arn
  engine_origin_host   = module.compute_engine.private_dns
  enable_waf           = var.enable_waf
  tags                 = local.tags
}

# Cloud image builds and the deploy mechanism. Digests are changed by deployments (SSM), never by an apply;
# the deployer policies below are for the IAM users or roles the human creates for the service teams.
locals {
  # One build project per repository created by terraform/bootstrap. core-runtime is built from the improvement-engine
  # repo (core-bridge/) with the pinned agent-core checkout as the named build context "core".
  build_services = {
    "core-runtime"         = { repository = "${var.ecr_repository_prefix}/core-runtime", dockerfile = "core-bridge/Dockerfile", core_context_dir = "agent-core" }
    "llm-gateway"          = { repository = "${var.ecr_repository_prefix}/llm-gateway" }
    "support-platform-api" = { repository = "${var.ecr_repository_prefix}/support-platform-api", dockerfile = "api/Dockerfile", context_dir = "api" }
    "support-platform-web" = { repository = "${var.ecr_repository_prefix}/support-platform-web", dockerfile = "web/Dockerfile", context_dir = "web" }
    "pulso-engine"         = { repository = "${var.ecr_repository_prefix}/pulso-engine" }
    "caddy"                = { repository = "${var.ecr_repository_prefix}/caddy", mode = "mirror" }
  }
}

module "image_builder" {
  source       = "../../modules/image_builder"
  name         = var.name_prefix
  enabled      = var.enable_image_builder
  region       = var.region
  bucket_name  = module.data.bucket_name
  kms_key_arn  = module.data.kms_key_arn
  ecr_registry = local.ecr_registry_url
  services     = local.build_services
  compute_type = var.image_builder_compute_type
  tags         = local.tags
}

module "deployers" {
  source      = "../../modules/deployer_policies"
  region      = var.region
  ssm_prefix  = module.data.ssm_prefix
  bucket_name = module.data.bucket_name
  kms_key_arn = module.data.kms_key_arn
  workloads = {
    core = {
      image_keys     = ["core", "gateway"]
      repositories   = ["${var.ecr_repository_prefix}/core-runtime", "${var.ecr_repository_prefix}/llm-gateway"]
      build_services = ["core-runtime", "llm-gateway"]
    }
    platform = {
      image_keys     = ["support_api", "support_web"]
      repositories   = ["${var.ecr_repository_prefix}/support-platform-api", "${var.ecr_repository_prefix}/support-platform-web"]
      build_services = ["support-platform-api", "support-platform-web"]
    }
    engine = {
      image_keys     = ["pulso"]
      repositories   = ["${var.ecr_repository_prefix}/pulso-engine"]
      build_services = ["pulso-engine"]
    }
  }
  project_arns = module.image_builder.project_arns
}
