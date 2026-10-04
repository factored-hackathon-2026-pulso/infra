output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.this.domain_name
}

output "cloudfront_distribution_id" {
  value = aws_cloudfront_distribution.this.id
}

output "vpc_origin_ids" {
  description = "VPC origin ids by workload (platform, engine)."
  value       = { for k, v in aws_cloudfront_vpc_origin.this : k => v.id }
}

output "web_acl_arn" {
  description = "Null when WAF is disabled."
  value       = one(aws_wafv2_web_acl.this[*].arn)
}
