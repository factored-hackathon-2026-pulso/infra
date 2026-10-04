# hackathon_edge

One CloudFront distribution in front of two private hosts (ADR 0007).

- Origins: two CloudFront **VPC origins** (`aws_cloudfront_vpc_origin`, present in the pinned provider
  `~> 5.0`, resolved 5.100): `platform` (default, :80) and `engine` (`/pulso/*`, :8080). Each targets an EC2
  instance ARN directly (or an internal ALB/NLB ARN if one is added later). Core and the gateway are never exposed.
- Routing: `/pulso/*` goes to the engine; everything else (`/`, `/api`, `/api/v1/ws` WebSocket) goes to the platform.
- Both behaviours use `Managed-CachingDisabled` plus `Managed-AllViewer` (forwards all headers, so WebSocket upgrades
  work), all methods, compression, redirect to HTTPS.
- Security headers policy: HSTS, nosniff, frame DENY, referrer policy.
- Header `X-Origin-Verify` from `origin_secret` (sensitive) on both origins; the reverse proxies should reject requests
  without it. Defense in depth: the VPC origin and the host security groups already limit who can connect. Feed it
  from SSM Parameter Store, never hard-code it.
- Origin protocol is HTTP by default; inside a VPC origin the hop stays on the AWS network. `https-only` needs a
  certificate on the host proxy.
- WAF (`enable_waf`, default **true**): WAFv2 web ACL, scope CLOUDFRONT, created through the `aws.us_east_1`
  provider alias. Rules: CommonRuleSet, KnownBadInputsRuleSet, per-IP rate limit (`waf_rate_limit`,
  `waf_rate_window_seconds`). About 5 USD per ACL per month, 1 USD per rule (3 rules), 0.60 USD per million
  requests; `enable_waf = false` avoids it.

Callers pass `providers = { aws = aws, aws.us_east_1 = aws.us_east_1 }`.

Outputs: `cloudfront_domain_name`, `cloudfront_distribution_id`, `vpc_origin_ids`, `web_acl_arn`.

Note: because of the `aws.us_east_1` alias, standalone `terraform validate` in this directory reports a missing
provider configuration; `terraform test` (which supplies mock providers) and a root that passes both providers
validate it.

Test: `terraform init -backend=false && terraform test` (mock providers).
