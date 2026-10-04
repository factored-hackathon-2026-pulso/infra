# Hackathon one-host-per-workload profile

Status: **Proposed**. It deliberately deviates from [ADR 0003](0003-agent-core-workload.md),
[ADR 0004](0004-llm-gateway-workload.md) and [ADR 0005](0005-agent-core-escalado-fase-0-1.md) for a
short-lived hackathon environment. Merging the Terraform creates no resources: nothing is applied
(ADR 0002 item 7).

## Context

The hackathon runs on a brand new, empty AWS account that may be on the credit model rather than the 12-month
free tier. Cost matters more than scale or availability. ADRs 0003 to 0005 assume Fargate services, NAT per AZ,
Secrets Manager and RDS Proxy: the right shape for a real environment, but several fixed monthly charges and many
moving parts for a demo that needs three hosts and one database.

Paid components are allowed when they remove work or risk, but each is chosen at its cheapest shape.

## Decision

One VPC in two AZs, in `us-east-1` by default (a `region` variable, never hard-coded elsewhere).

1. **Subnets.** Public subnets hold only the NAT gateway. Private subnets (no public IP, default route to the
   NAT) hold the compute host. Isolated db subnets have no default route and exist for the RDS subnet group.
2. **One NAT gateway**, in AZ a, one Elastic IP. The host reaches ECR, SSM and model APIs through it.
3. **S3 gateway endpoint** (free) on the private route table so S3 traffic bypasses the NAT and its per-GB charge.
4. **One EC2 host per workload**, all in private subnets, Docker Compose on each (lane C), instead of Fargate:
   - `core`: core-runtime, core-exporter, core-migrate and llm-gateway together; the gateway is reached only over
     localhost or the compose network and is never exposed.
   - `platform`: support-platform API :8000 inside the host, web and reverse proxy; the proxy listens on :80.
   - `engine`: `pulso` on :8080, console under `/pulso/`.
   No Redis, no RDS Proxy.
5. **No SSH.** Access is SSM Session Manager (roles have `AmazonSSMManagedInstanceCore`).
6. **SSM Parameter Store** (standard tier, free) instead of Secrets Manager. Each host role reads only
   `<root>/<workload>/*`.
7. **Public edge is one CloudFront distribution with two VPC origins** (`aws_cloudfront_vpc_origin`, available in
   the pinned AWS provider 5.x; verified present in 5.100), each targeting a host instance directly (an internal
   ALB/NLB can replace it later). `/pulso/*` goes to the engine; everything else (`/`, `/api`, `/api/v1/ws`
   WebSocket) goes to the platform. Core and the gateway have no edge path.
8. **Security groups per workload.** platform :80 and engine :8080 accept ingress only from the CloudFront
   origin-facing managed prefix list (`com.amazonaws.global.cloudfront.origin-facing`), plus optionally the
   CloudFront VPC-origin service SG (AWS creates it with the first VPC origin; pass its id as
   `cloudfront_vpc_origin_sg_id` on a second apply) and an optional `admin_cidr` (empty by default). Core :8000
   accepts only the engine and platform SGs. Platform and engine egress: 443, 5432 to `sg_db`, 8000 to core, DNS.
   Core egress: 443 (LLM providers and api.typesafe.ai via the NAT), 5432 to `sg_db`, DNS. `sg_db` accepts 5432
   only from the three host SGs.
9. **WAF is on by default** (web ACL, scope CLOUDFRONT, created in us-east-1 through a provider alias) with
   the AWS managed CommonRuleSet and KnownBadInputsRuleSet and a per-IP rate-based rule; `enable_waf = false`
   turns it off.
10. **Origin trust.** CloudFront to origin uses HTTP inside the VPC origin by default and adds a secret
    `X-Origin-Verify` header the host reverse proxy checks.

A **private Route 53 zone** (default `pulso.internal`, output `zone_id`) gives hosts stable names for each other;
the compute lane creates the records.

Instance roles are least privilege per host: core reads its parameters, pulls its images and uses `core/blobs`;
platform pulls its images and reads its parameters; engine pulls its images, reads its parameters, uses `engine/`
and reads `landing/` and `lake/` through loader prefix variables.

Modules: `hackathon_network`, `hackathon_iam`, `hackathon_edge` (this change); `hackathon_data` and
`hackathon_compute` plus the composition `envs/hackathon` come from other lanes.

### Origin transport trade-off

| Option | Gain | Cost |
| --- | --- | --- |
| HTTP over the VPC origin plus header (default) | No certificate to issue or renew on the host | Traffic is unencrypted on the last hop, inside the AWS network and a private subnet |
| HTTPS to the origin | Encrypted end to end | The host proxy needs a certificate trusted by CloudFront (public CA for the origin name); more setup |

The secret header is defense in depth: with a VPC origin and the prefix-list security group there is no public
path to the host at all, so the header only matters if the SG is widened later by mistake.

## What this gives up versus ADRs 0003 to 0005

- No high availability: one host per workload, one NAT in one AZ (an AZ-a outage cuts egress; a host failure is an
  outage of that workload until replaced), likely single-AZ RDS.
- No autoscaling, rolling deploys or Fargate task isolation per service; services of one workload share a host and its blast radius (core and the gateway share one).
- No Secrets Manager rotation or audit trail; Parameter Store has neither rotation nor per-secret resource policies.
- No RDS Proxy: connection pooling falls to the application (ADR 0005 item on connection growth is not met).
- No Redis, so anything ADR 0005 moved there stays in Postgres or in memory.
- No per-service load balancer, listener rules or target-group health gates.
- No VPC interface endpoints for ECR, SSM and logs: those calls go through the NAT.

## Security mitigations

- Hosts have no public IP, no SSH and no inbound path except CloudFront (and core only from engine and platform); db subnets have no internet route.
- Security groups reference each other, not CIDRs; no wildcard egress except 443.
- Instance roles have no IAM or Organizations rights: scoped statements plus a permissions boundary that denies
  `iam:*`, `organizations:*`, `account:*` and `sts:AssumeRole`.
- S3 access limited to one bucket and listed prefixes; parameter reads limited to one path; log writes limited
  to a name prefix. The only `Resource: "*"` is `ecr:GetAuthorizationToken`, which AWS does not scope.
- Edge: HTTPS-only viewer policy, HSTS, nosniff, frame deny, WAF managed rules and rate limit.
- Secrets live in Parameter Store (SecureString) and never in Terraform variables committed to Git; the origin
  secret is a sensitive variable fed from there.
- Flow logs are optional (off by default; cost).

## Cost (us-east-1 list prices, approximate, verify before relying on them)

| Item | Free or paid | Approx. cost | Why |
| --- | --- | --- | --- |
| VPC, subnets, route tables, IGW, security groups | Free | 0 | |
| S3 gateway endpoint | Free | 0 | Keeps S3 bytes off the NAT |
| NAT gateway (one) | **Paid** | about 32 USD/month plus 0.045 USD/GB processed | Private host needs egress; cheapest correct shape; the largest fixed cost in this profile |
| Public IPv4 for the NAT EIP | **Paid** | about 3.6 USD/month | One address; the host has none |
| CloudFront distribution | Free tier (1 TB out, 10 M requests per month, always free) | 0 within tier | |
| CloudFront VPC origin | No separate charge at time of writing | 0 | Verify on the pricing page |
| WAF web ACL | **Paid** | about 5 USD/month ACL, 1 USD per rule (3 rules), 0.60 USD per million requests, so roughly 8 USD/month plus traffic | Opt out with `enable_waf = false` |
| SSM Parameter Store (standard), Session Manager | Free | 0 | |
| IAM roles and policies | Free | 0 | |
| VPC flow logs | **Paid** when enabled | CloudWatch ingestion and storage | Default off |
| Route 53 private hosted zone | **Paid** | 0.50 USD/month per zone plus negligible queries | Stable internal names |
| EC2 hosts (3), RDS, S3, ECR, CloudWatch | Lanes B and C | | Outside this change |

Fixed floor from this change: about 46 USD/month with WAF, about 37 USD/month without (NAT, its address, zone, WAF). Both are low enough
for a short hackathon; destroy the stack afterwards.

## Graduating to Fargate and per-AZ NAT

1. Add a second NAT (one per AZ) and a route table per private subnet; the `private_subnet_ids` output is already
   two subnets across two AZs.
2. Replace the hosts with ECS services behind an internal ALB; point `origin_arn` at the ALB (the VPC origin
   already supports it) and drop the instance-level security group rules.
3. Add VPC interface endpoints for ECR, SSM and logs where the NAT data charge exceeds their hourly cost.
4. Move parameters that need rotation to Secrets Manager; add RDS Proxy and Multi-AZ per ADR 0005; add Redis if required.
5. Adopt the ADR 0003 to 0005 modules (`network`, `workload`, `core_data`) in place of the `hackathon_*` ones.

## Implementation status

Modules and tests exist (`terraform test` with mock providers); nothing is applied and nothing here is verified
against AWS. Whether a CloudFront VPC origin can target an EC2 instance directly in the chosen region, and the
exact service security group behaviour (and that a VPC origin can target an instance in a private subnet), must be confirmed at the first apply.
