output "cloudfront_domain_name" { value = one(module.edge[*].cloudfront_domain_name) }
output "cloudfront_distribution_id" { value = one(module.edge[*].cloudfront_distribution_id) }

output "instance_ids" {
  value = {
    core     = module.compute_core.instance_id
    platform = module.compute_platform.instance_id
    engine   = module.compute_engine.instance_id
  }
}

output "private_ips" {
  value = {
    core     = module.compute_core.private_ip
    platform = module.compute_platform.private_ip
    engine   = module.compute_engine.private_ip
  }
}

output "db_endpoint" {
  description = "RDS endpoint, or the core host private DNS name (Postgres container) in container mode. Use it in the DSNs stored in the secret."
  value       = local.container_db ? module.compute_core.private_zone_record : module.data.db_endpoint
}
output "bucket_name" { value = module.data.bucket_name }
output "ssm_prefix" { value = module.data.ssm_prefix }
output "secret_arn" { value = module.data.secret_arn }
output "kms_key_arn" { value = module.data.kms_key_arn }
output "instance_role_arns" {
  value = {
    core     = module.iam.instance_role_arn_core
    platform = module.iam.instance_role_arn_platform
    engine   = module.iam.instance_role_arn_engine
  }
}
output "uploader_policy_json" { value = module.data.uploader_policy_json }
output "loader_policy_json" { value = module.data.loader_policy_json }
output "private_zone_name" { value = module.network.zone_name }
output "environment" { value = var.environment }
output "name_prefix" { value = var.name_prefix }
output "ecr_registry_url_effective" { value = local.ecr_registry_url }
output "loader_role_arns_effective" { value = local.loader_roles }
output "uploader_principal_arns_effective" { value = local.uploader_principals }
output "break_glass_principal_arns_effective" { value = local.break_glass }
output "ecr_repository_arns_effective" { value = local.ecr_arns }
output "image_build_projects" {
  description = "CodeBuild project per service (empty when enable_image_builder is false)."
  value       = module.image_builder.project_names
}

output "deployer_policy_json_core" {
  description = "Identity policy for the agent-core and llm-gateway teams (core host). The human attaches it to the IAM users or roles he creates."
  value       = module.deployers.deployer_policy_json_core
}

output "deployer_policy_json_platform" {
  description = "Identity policy for the support-platform team (platform host)."
  value       = module.deployers.deployer_policy_json_platform
}

output "deployer_policy_json_engine" {
  description = "Identity policy for the engine team (engine host)."
  value       = module.deployers.deployer_policy_json_engine
}

output "deploy_documents" {
  description = "SSM Command document that deploys the digests stored in SSM, per host."
  value = {
    core     = module.compute_core.deploy_document_name
    platform = module.compute_platform.deploy_document_name
    engine   = module.compute_engine.deploy_document_name
  }
}

output "host_user_data_sha256" {
  description = "Hash of each host start script. A digest-only deploy never changes it; a change means the instance would be replaced."
  value = {
    core     = module.compute_core.user_data_sha256
    platform = module.compute_platform.user_data_sha256
    engine   = module.compute_engine.user_data_sha256
  }
}

output "host_public_dns" {
  description = "Public DNS names of the hosts (free_plan; inbound is closed by the security groups except the CloudFront prefix list on the proxies)."
  value = {
    core     = module.compute_core.public_dns
    platform = module.compute_platform.public_dns
    engine   = module.compute_engine.public_dns
  }
}

output "profile_effective" {
  description = "Resolved profile values (what the profile and the overrides produced)."
  value = {
    profile                    = var.profile
    database_mode              = local.db_mode
    nat_gateway                = local.nat
    hosts_public_ip            = local.public_hosts
    edge_origin_mode           = local.origin_mode
    edge_enabled               = local.edge
    waf                        = local.waf
    host_builder               = local.host_builder
    instance_types             = local.instance_types
    image_builder_compute_type = local.compute_type
  }
}
