output "cloudfront_domain_name" { value = module.edge.cloudfront_domain_name }
output "cloudfront_distribution_id" { value = module.edge.cloudfront_distribution_id }

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

output "db_endpoint" { value = module.data.db_endpoint }
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
