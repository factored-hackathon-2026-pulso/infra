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

  # Profile (free_plan | prod): every derived value can be overridden by its own variable.
  free_plan    = var.profile == "free_plan"
  db_mode      = coalesce(var.database_mode, local.free_plan ? "container" : "rds")
  nat          = var.enable_nat == null ? !local.free_plan : var.enable_nat
  waf          = var.enable_waf == null ? !local.free_plan : var.enable_waf
  host_builder = var.enable_host_builder == null ? local.free_plan : var.enable_host_builder
  instance_types = coalesce(var.instance_types, local.free_plan ?
    { core = "m7i-flex.large", platform = "t3.small", engine = "t3.small" } :
  { core = "t3.small", platform = "t3.small", engine = "t3.small" })
  compute_type = coalesce(var.image_builder_compute_type, local.free_plan ? "BUILD_GENERAL1_SMALL" : "BUILD_GENERAL1_MEDIUM")
  container_db = local.db_mode == "container"
  public_hosts = !local.nat
  origin_mode  = local.public_hosts ? "public" : "vpc"
  edge         = var.edge_enabled == null ? true : var.edge_enabled

  # Postgres container bundle on the core host: compose override and the repository SQL run by the initdb script.
  core_db_files = local.container_db ? {
    "compose.postgres.yaml"             = file("${path.module}/../../../deploy/hackathon/core/compose.postgres.yaml")
    "initdb/10_init.sh"                 = file("${path.module}/../../../deploy/hackathon/core/initdb/10_init.sh")
    "initdb/sql/00_databases_roles.sql" = file("${path.module}/../../modules/hackathon_data/sql/00_databases_roles.sql")
    "initdb/sql/10_core_grants.sql"     = file("${path.module}/../../modules/hackathon_data/sql/10_core_grants.sql")
    "initdb/sql/30_pulso_logins.sql"    = file("${path.module}/../../modules/hackathon_data/sql/30_pulso_logins.sql")
    "bootstrap/pulso-db-bootstrap.sh"   = file("${path.module}/../../../deploy/hackathon/core/bootstrap/pulso-db-bootstrap.sh")
  } : {}

  # Agent services (docs/agent-services.md): agent-core serve and tool-service on the core host, the platform side.
  agents      = var.agent_services_enabled
  platform_db = var.platform_database_enabled
  core_agent_files = local.agents ? merge(
    { "compose.agents.yaml" = file("${path.module}/../../../deploy/hackathon/core/compose.agents.yaml") },
    local.container_db ? { "initdb/sql/20_agent_databases.sql" = file("${path.module}/../../modules/hackathon_data/sql/20_agent_databases.sql") } : {},
    # Shared Postgres: platform and tool-service databases; the exporter grants run by hand after the platform's first migration.
    local.container_db && local.platform_db ? {
      "initdb/sql/25_platform_databases.sql"       = file("${path.module}/../../modules/hackathon_data/sql/25_platform_databases.sql")
      "initdb/sql/26_platform_exporter_grants.sql" = file("${path.module}/../../modules/hackathon_data/sql/26_platform_exporter_grants.sql")
    } : {},
  ) : {}
  platform_agent_files = local.agents ? { "compose.agents.yaml" = file("${path.module}/../../../deploy/hackathon/platform/compose.agents.yaml") } : {}
  restricted_readers   = local.agents ? [module.iam.instance_role_arn_core] : []

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
  source        = "../../modules/hackathon_network"
  name          = var.name_prefix
  region        = var.region
  enable_nat    = local.nat
  database_mode = local.db_mode

  agent_services_enabled = local.agents
  tags                   = local.tags
}

module "data" {
  source        = "../../modules/hackathon_data"
  name_prefix   = var.name_prefix
  region        = var.region
  vpc_id        = module.network.vpc_id
  database_mode = local.db_mode
  db_subnet_ids = module.network.db_subnet_ids
  sg_db_id      = module.network.sg_db_id

  # Deny-only bucket policy: the reads of landing/ are bound to the S3 gateway endpoint of this VPC.
  db_deletion_protection     = var.db_deletion_protection
  db_skip_final_snapshot     = var.db_skip_final_snapshot
  s3_vpc_endpoint_id         = module.network.s3_gateway_endpoint_id
  loader_role_arns           = local.loader_roles
  uploader_principal_arns    = local.uploader_principals
  break_glass_principal_arns = local.break_glass

  # tool-service on the core host reads data-pipeline's restricted publication (gold_restricted, PII in the clear).
  agent_services_enabled      = local.agents
  platform_database_enabled   = local.platform_db
  agent_keys_suffix           = var.agent_keys_suffix
  restricted_reader_role_arns = local.restricted_readers
  tags                        = local.tags
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
  # tool-service syncs the current publication (latest.json, gold_restricted.duckdb, field_classification.json).
  # agent-core serve syncs its calibration and classifier artifacts from core/artifacts/.
  core_read_prefixes = local.agents ? ["lake/publish", "core/artifacts"] : []

  ecr_repository_arns_core     = local.ecr_arns.core
  ecr_repository_arns_platform = local.ecr_arns.platform
  ecr_repository_arns_engine   = local.ecr_arns.engine
  enable_host_builder          = local.host_builder
  ecr_push_repository_arns     = distinct(concat(local.ecr_arns.core, local.ecr_arns.platform, local.ecr_arns.engine))
  tags                         = local.tags
}
# One EC2 per workload; each reads only its own slice of the one secret.
module "compute_core" {
  source                  = "../../modules/hackathon_compute"
  name_prefix             = var.name_prefix
  region                  = var.region
  workload                = "core"
  enabled                 = var.enabled["core"]
  instance_type           = local.instance_types["core"]
  subnet_id               = module.network.host_subnet_ids[0]
  associate_public_ip     = local.public_hosts
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
  db_volume_size_gb       = local.container_db ? var.db_volume_size_gb : 0
  extra_service_envs      = concat(local.container_db ? ["db"] : [], local.agents ? ["agent", "tools"] : [])
  compose_files           = concat(["compose.yaml"], local.container_db ? ["compose.postgres.yaml"] : [], local.agents ? ["compose.agents.yaml"] : [])
  extra_bundle_files      = merge(local.core_db_files, local.core_agent_files)
  extra_ports             = concat(["8080:8080"], local.agents ? ["8001:8001"] : [])
  extra_env               = local.agents ? { AGENT_SERVE_ARGS = var.agent_serve_args } : {}
  tags                    = local.tags
}

module "compute_platform" {
  source                  = "../../modules/hackathon_compute"
  name_prefix             = var.name_prefix
  region                  = var.region
  workload                = "platform"
  enabled                 = var.enabled["platform"]
  instance_type           = local.instance_types["platform"]
  subnet_id               = module.network.host_subnet_ids[0]
  associate_public_ip     = local.public_hosts
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
  compose_files           = local.agents ? ["compose.yaml", "compose.agents.yaml"] : ["compose.yaml"]
  extra_bundle_files      = local.platform_agent_files
  extra_ports             = local.agents ? ["8000:8000"] : []
  tags                    = local.tags
}

module "compute_engine" {
  source                  = "../../modules/hackathon_compute"
  name_prefix             = var.name_prefix
  region                  = var.region
  workload                = "engine"
  enabled                 = var.enabled["engine"]
  instance_type           = local.instance_types["engine"]
  subnet_id               = module.network.host_subnet_ids[0]
  associate_public_ip     = local.public_hosts
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
  count  = local.edge ? 1 : 0
  source = "../../modules/hackathon_edge"
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name                 = var.name_prefix
  platform_origin_arn  = module.compute_platform.instance_arn
  origin_mode          = local.origin_mode
  origin_secret        = module.data.origin_verify_secret
  platform_origin_host = local.public_hosts ? module.compute_platform.public_dns : module.compute_platform.private_dns
  engine_origin_arn    = module.compute_engine.instance_arn
  engine_origin_host   = local.public_hosts ? module.compute_engine.public_dns : module.compute_engine.private_dns
  enable_waf           = local.waf
  tags                 = local.tags
}

# Cloud image builds and the deploy mechanism. Digests are changed by deployments (SSM), never by an apply;
# the deployer policies below are for the IAM users or roles the human creates for the service teams.
locals {
  # One build project per repository created by terraform/bootstrap. core-runtime is built from the improvement-engine
  # repo (core-bridge/) with the pinned agent-core checkout as the named build context "core".
  build_services = {
    "core-runtime"         = { repository = "${var.ecr_repository_prefix}/core-runtime", dockerfile = "core-bridge/Dockerfile", context_dir = "core-bridge", core_context_dir = "agent-core" }
    "llm-gateway"          = { repository = "${var.ecr_repository_prefix}/llm-gateway" }
    "support-platform-api" = { repository = "${var.ecr_repository_prefix}/support-platform-api", dockerfile = "backend/Dockerfile", context_dir = "backend" }
    "support-platform-web" = { repository = "${var.ecr_repository_prefix}/support-platform-web", dockerfile = "frontend/Dockerfile", context_dir = "frontend" }
    "pulso-engine"         = { repository = "${var.ecr_repository_prefix}/pulso-engine" }
    "caddy"                = { repository = "${var.ecr_repository_prefix}/caddy", mode = "mirror" }
  }
  # agent-core serve is built from the agent-core repo's own Dockerfile (not core-bridge); tool-service from its repo.
  agent_build_services = local.agents ? {
    "agent-core-serve" = { repository = "${var.ecr_repository_prefix}/agent-core-serve" }
    "tool-service"     = { repository = "${var.ecr_repository_prefix}/tool-service" }
  } : {}
}

module "image_builder" {
  source       = "../../modules/image_builder"
  name         = var.name_prefix
  enabled      = var.enable_image_builder
  region       = var.region
  bucket_name  = module.data.bucket_name
  kms_key_arn  = module.data.kms_key_arn
  ecr_registry = local.ecr_registry_url
  services     = merge(local.build_services, local.agent_build_services)
  compute_type = local.compute_type
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
      image_keys     = concat(["core", "gateway"], local.agents ? ["agent", "tools"] : [])
      repositories   = concat(["${var.ecr_repository_prefix}/core-runtime", "${var.ecr_repository_prefix}/llm-gateway"], local.agents ? ["${var.ecr_repository_prefix}/agent-core-serve", "${var.ecr_repository_prefix}/tool-service"] : [])
      build_services = concat(["core-runtime", "llm-gateway"], keys(local.agent_build_services))
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

# Engine -> shared Core and gateway addresses. The engine client only accepts IP literals (or localhost) for plaintext hosts, so
# these are the core host's private IP, not its DNS name. The shared Core is agent-core serve (:8001) when agent_services_enabled
# (ADR 0009); the IP changes if the core instance is replaced and the next apply rewrites the values.
resource "aws_ssm_parameter" "engine_core_addr" {
  for_each = {
    PULSO_CORE_ADDR        = "${module.compute_core.private_ip}:${local.agents ? 8001 : 8000}"
    PULSO_LLM_GATEWAY_ADDR = "${module.compute_core.private_ip}:8080"
  }
  name  = "${module.data.ssm_prefix}/engine/pulso/${each.key}"
  type  = "String"
  value = each.value
  tags  = local.tags
}

# Engine -> platform (announce route and evidence, docs/shared-postgres.md) and engine -> serve registry. The engine client
# accepts only a private IP literal or localhost for plain HTTP (PULSO_PLATFORM_URL, PULSO_REGISTRY_ADDR), so these are the
# hosts' private IPs; the next apply rewrites them if an instance is replaced. The platform API is published on :8000 for
# the core and engine security groups only (agent_services_enabled); the proxy on :80 keeps refusing /api/v1/internal/*.
# The platform event log is read through the read-only database role (PULSO__PULSO_PG_PRODUCT_DSN, adapter product-postgres, schema public).
resource "aws_ssm_parameter" "engine_platform" {
  for_each = local.platform_db ? {
    PULSO_PLATFORM_URL         = "http://${module.compute_platform.private_ip}:8000"
    PULSO_REGISTRY_ADDR        = "${module.compute_core.private_ip}:8001"
    PULSO_ANNOUNCE_TO_PLATFORM = "on"
    PULSO_SOURCE_ADAPTER       = "product-postgres"
    PULSO_SOURCE_SCHEMA        = "public"
  } : {}
  name  = "${module.data.ssm_prefix}/engine/pulso/${each.key}"
  type  = "String"
  value = each.value
  tags  = local.tags
}
