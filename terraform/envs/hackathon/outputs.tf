output "cloudfront_domain_name" { value = module.edge.cloudfront_domain_name }
output "cloudfront_distribution_id" { value = module.edge.cloudfront_distribution_id }
output "instance_id" { value = module.compute.instance_id }
output "db_endpoint" { value = module.data.db_endpoint }
output "bucket_name" { value = module.data.bucket_name }
output "ssm_prefix" { value = module.data.ssm_prefix }
