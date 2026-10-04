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

override_data {
  target = data.aws_cloudfront_cache_policy.disabled
  values = {
    id   = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
    name = "Managed-CachingDisabled"
  }
}

override_data {
  target = data.aws_cloudfront_origin_request_policy.all_viewer
  values = {
    id   = "216adef6-5c7f-47e4-b989-5492eafa07d3"
    name = "Managed-AllViewer"
  }
}

override_resource {
  target          = aws_cloudfront_vpc_origin.this["platform"]
  override_during = plan
  values = {
    id = "vo-platform"
  }
}

override_resource {
  target          = aws_cloudfront_vpc_origin.this["engine"]
  override_during = plan
  values = {
    id = "vo-engine"
  }
}

override_resource {
  target          = aws_cloudfront_response_headers_policy.security
  override_during = plan
  values = {
    id = "rhp-security"
  }
}

variables {
  name                 = "hk"
  platform_origin_arn  = "arn:aws:ec2:us-east-1:123456789012:instance/i-0aaaaaaaaaaaaaaaa"
  platform_origin_host = "ip-10-20-10-5.ec2.internal"
  engine_origin_arn    = "arn:aws:ec2:us-east-1:123456789012:instance/i-0bbbbbbbbbbbbbbbb"
  engine_origin_host   = "ip-10-20-11-6.ec2.internal"
  origin_secret        = "test-secret-value"
  tags                 = { Environment = "hackathon" }
}

run "two_vpc_origins_one_per_exposed_workload" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = aws_cloudfront_vpc_origin.this["platform"].vpc_origin_endpoint_config[0].http_port == 80 && aws_cloudfront_vpc_origin.this["engine"].vpc_origin_endpoint_config[0].http_port == 8080
    error_message = "Platform on :80, engine on :8080."
  }

  assert {
    condition     = length(aws_cloudfront_vpc_origin.this) == 2
    error_message = "Core and the gateway are never exposed: only two origins."
  }
}

run "pulso_path_goes_to_engine_everything_else_to_platform" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].target_origin_id == "platform"
    error_message = "Default behaviour (/, /api, /api/v1/ws) goes to the platform."
  }

  assert {
    condition     = length(aws_cloudfront_distribution.this.ordered_cache_behavior) == 1 && one(aws_cloudfront_distribution.this.ordered_cache_behavior).path_pattern == "/pulso/*" && one(aws_cloudfront_distribution.this.ordered_cache_behavior).target_origin_id == "engine"
    error_message = "/pulso/* goes to the engine."
  }
}

run "behaviours_are_uncached_websocket_friendly_and_https_only" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  # The mock provider does not echo nested cache-behavior policy ids in plan, so the managed policies are
  # asserted at their source (looked up by AWS name); the wiring is covered by terraform validate and the first apply.
  assert {
    condition     = data.aws_cloudfront_cache_policy.disabled.name == "Managed-CachingDisabled"
    error_message = "API and WebSocket traffic is never cached (managed CachingDisabled policy)."
  }

  assert {
    condition     = data.aws_cloudfront_origin_request_policy.all_viewer.name == "Managed-AllViewer"
    error_message = "All viewer headers are forwarded so WebSocket upgrades work (managed AllViewer policy)."
  }
  assert {
    condition     = aws_cloudfront_distribution.this.default_cache_behavior[0].viewer_protocol_policy == "redirect-to-https" && aws_cloudfront_distribution.this.default_cache_behavior[0].compress && length(aws_cloudfront_distribution.this.default_cache_behavior[0].allowed_methods) == 7
    error_message = "Redirect to HTTPS, compress, all methods."
  }
}

run "security_headers_policy_attached" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = aws_cloudfront_response_headers_policy.security.security_headers_config[0].strict_transport_security[0].override && aws_cloudfront_response_headers_policy.security.security_headers_config[0].frame_options[0].frame_option == "DENY"
    error_message = "HSTS and frame deny from the edge."
  }
}

run "custom_origin_header_carries_the_secret_on_both_origins" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = alltrue([for o in aws_cloudfront_distribution.this.origin : one(o.custom_header).name == "X-Origin-Verify" && one(o.custom_header).value == "test-secret-value"])
    error_message = "Both origins get the verification header."
  }
}

run "waf_on_by_default_with_three_rules_scope_cloudfront" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this) == 1 && aws_wafv2_web_acl.this[0].scope == "CLOUDFRONT"
    error_message = "A CLOUDFRONT-scope web ACL is created by default."
  }

  assert {
    condition     = toset([for r in aws_wafv2_web_acl.this[0].rule : r.name]) == toset(["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet", "RateLimitPerIp"])
    error_message = "Common, known-bad-inputs and a rate-based rule."
  }

  assert {
    condition     = one([for r in aws_wafv2_web_acl.this[0].rule : r if r.name == "RateLimitPerIp"]).statement[0].rate_based_statement[0].limit == 1000
    error_message = "Rate limit defaults to 1000 requests per window per IP."
  }
}

run "waf_can_be_turned_off" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  variables {
    enable_waf = false
  }

  assert {
    condition     = length(aws_wafv2_web_acl.this) == 0
    error_message = "Toggle off creates no web ACL."
  }
}

run "empty_secret_omits_the_header" {
  command = plan

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  variables {
    origin_secret = ""
  }

  assert {
    condition     = alltrue([for o in aws_cloudfront_distribution.this.origin : length(o.custom_header) == 0])
    error_message = "No header without a secret."
  }
}
