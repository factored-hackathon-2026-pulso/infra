# free_plan: CloudFront with PUBLIC origins (host public DNS). The host SG admits only the CloudFront prefix list and
# Caddy enforces the secret X-Origin-Verify header. Separate file: no VPC origin overrides apply here.
mock_provider "aws" {
  mock_data "aws_cloudfront_cache_policy" {
    defaults = {
      id = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    }
  }
  mock_data "aws_cloudfront_origin_request_policy" {
    defaults = {
      id = "216adef6-5c7f-47e4-b989-5492eafa07d3"
    }
  }
}

mock_provider "aws" {
  alias = "us_east_1"
}

variables {
  name                 = "hk"
  origin_mode          = "public"
  platform_origin_arn  = "arn:aws:ec2:us-east-1:123456789012:instance/i-0aaaaaaaaaaaaaaaa"
  platform_origin_host = "ec2-1-2-3-4.compute-1.amazonaws.com"
  engine_origin_arn    = "arn:aws:ec2:us-east-1:123456789012:instance/i-0bbbbbbbbbbbbbbbb"
  engine_origin_host   = "ec2-5-6-7-8.compute-1.amazonaws.com"
  origin_secret        = "test-secret-value"
  enable_waf           = false
  tags                 = { Environment = "hackathon" }
}

run "public_origins_use_custom_origin_config_and_the_secret_header" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = length(aws_cloudfront_vpc_origin.this) == 0
    error_message = "No VPC origins in public mode."
  }
  assert {
    condition     = length([for o in aws_cloudfront_distribution.this.origin : o if length(o.custom_origin_config) == 1 && length(o.vpc_origin_config) == 0]) == 2
    error_message = "Both origins are plain custom (public) origins."
  }
  assert {
    condition     = alltrue([for o in aws_cloudfront_distribution.this.origin : one(o.custom_origin_config).origin_protocol_policy == "http-only"])
    error_message = "http-only to the origin (the viewer leg is HTTPS; the origin leg is restricted by the prefix list and the secret header)."
  }
  assert {
    condition     = alltrue([for o in aws_cloudfront_distribution.this.origin : length([for h in o.custom_header : h if h.name == "X-Origin-Verify"]) == 1])
    error_message = "Every origin request carries X-Origin-Verify."
  }
  assert {
    condition     = aws_cloudfront_distribution.this.web_acl_id == null || aws_cloudfront_distribution.this.web_acl_id == ""
    error_message = "WAF off by default in free_plan (enable_waf=false)."
  }
}

run "origin_mode_is_validated" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    origin_mode = "tunnel"
  }
  expect_failures = [var.origin_mode]
}

run "public_mode_requires_the_secret" {
  command = plan
  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }
  variables {
    origin_secret = ""
  }
  expect_failures = [var.origin_secret]
}
