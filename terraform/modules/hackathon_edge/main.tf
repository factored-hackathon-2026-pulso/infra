# Public edge for the hackathon profile (ADR 0007): CloudFront with a VPC origin (origin_mode=vpc) or, in the free_plan
# profile (ADR 0008), a public origin (origin_mode=public) to two hosts (platform default, engine on /pulso/*), security headers, and an optional (default on) WAF.

data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

# Forwards every viewer header (including Upgrade/Connection for WebSocket), cookies and query strings.
data "aws_cloudfront_origin_request_policy" "all_viewer" {
  name = "Managed-AllViewer"
}

locals {
  origins = {
    platform = { arn = var.platform_origin_arn, host = var.platform_origin_host, port = var.platform_http_port }
    engine   = { arn = var.engine_origin_arn, host = var.engine_origin_host, port = var.engine_http_port }
  }
}

resource "aws_cloudfront_vpc_origin" "this" {
  for_each = var.origin_mode == "vpc" ? local.origins : {}

  vpc_origin_endpoint_config {
    name                   = "${var.name}-${each.key}"
    arn                    = each.value.arn
    http_port              = each.value.port
    https_port             = 443
    origin_protocol_policy = var.origin_protocol_policy

    origin_ssl_protocols {
      items    = ["TLSv1.2"]
      quantity = 1
    }
  }

  tags = var.tags
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${var.name}-security-headers"

  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    content_type_options {
      override = true
    }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "strict-origin-when-cross-origin"
      override        = true
    }
  }
}

resource "aws_wafv2_web_acl" "this" {
  provider = aws.us_east_1
  count    = var.enable_waf ? 1 : 0

  name  = "${var.name}-edge"
  scope = "CLOUDFRONT"
  tags  = var.tags

  default_action {
    allow {}
  }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 10
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "AWSManagedRulesKnownBadInputsRuleSet"
    priority = 20
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-badinputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "RateLimitPerIp"
    priority = 30
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit                 = var.waf_rate_limit
        evaluation_window_sec = var.waf_rate_window_seconds
        aggregate_key_type    = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-edge"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  comment         = "${var.name} hackathon edge"
  price_class     = var.price_class
  http_version    = "http2and3"
  is_ipv6_enabled = true
  web_acl_id      = one(aws_wafv2_web_acl.this[*].arn)
  tags            = var.tags

  dynamic "origin" {
    for_each = local.origins
    content {
      origin_id   = origin.key
      domain_name = origin.value.host

      dynamic "vpc_origin_config" {
        for_each = var.origin_mode == "vpc" ? [1] : []
        content {
          vpc_origin_id = aws_cloudfront_vpc_origin.this[origin.key].id
        }
      }

      # Public origin (free_plan): the host public DNS; the origin SG admits only the CloudFront prefix list.
      dynamic "custom_origin_config" {
        for_each = var.origin_mode == "public" ? [1] : []
        content {
          http_port              = origin.value.port
          https_port             = 443
          origin_protocol_policy = var.origin_protocol_policy
          origin_ssl_protocols   = ["TLSv1.2"]
        }
      }

      dynamic "custom_header" {
        for_each = nonsensitive(var.origin_secret) == "" ? [] : [1]
        content {
          name  = var.origin_secret_header_name
          value = var.origin_secret
        }
      }
    }
  }

  # Everything not matched below (/, /api, /api/v1/ws WebSocket) goes to the platform.
  default_cache_behavior {
    target_origin_id           = "platform"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  ordered_cache_behavior {
    path_pattern               = var.engine_path_pattern
    target_origin_id           = "engine"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}
