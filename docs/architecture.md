# Architecture (prod, us-east-1)

One AWS account, one environment (`prod`), three small EC2 hosts behind one CloudFront distribution. Everything is Terraform (`terraform/envs/hackathon` composes the modules; `terraform/bootstrap` is created first). Cross-checked against the code by `tests/test_docs_consistency.py`. Decision record: [ADR 0007](adr/0007-hackathon-single-host-profile.md); simplification: [decisions](decisions.md).

## Account diagram

```
 viewer ──HTTPS──> CloudFront (default domain + certificate) ── WAFv2 web ACL (scope CLOUDFRONT, us-east-1 alias)
                      │  two VPC origins, HTTP on the AWS network
                      │  /pulso/* -> engine :8080      everything else (/, /api, /api/v1/ws) -> platform :80
 ┌────────────────────┴─────────────── VPC 10.20.0.0/16, 2 AZs ───────────────────────────────────────────┐
 │ public subnets  : NAT gateway (one, AZ a) + internet gateway          (no hosts here)                   │
 │ private subnets : core host :8000     platform host :80     engine host :8080   (EC2 t3.small x3,       │
 │                   no public IP, no SSH, access by SSM Session Manager only, IMDSv2 required)            │
 │ db subnets      : RDS PostgreSQL 16 single-AZ :5432 (no default route, reachable from the 3 hosts only) │
 │ endpoints       : S3 gateway endpoint (free) on the private route table                                  │
 │ private DNS     : Route 53 private zone pulso.internal -> core.|platform.|engine.pulso.internal          │
 └─────────────────────────────────────────────────────────────────────────────────────────────────────────┘
 outside the VPC: S3 data bucket (SSE-KMS, deny-only bucket policy) · KMS data key · ONE Secrets Manager secret
                  pulso-prod/hackathon · SSM Parameter Store /pulso/<workload>/<service>/<VAR> (non-secret)
                  · ECR repositories pulso-prod/<repo> · remote state bucket pulso-prod-tfstate-<account id>
```

## Who talks to whom

| From | To | Port | Why |
|---|---|---|---|
| internet | CloudFront | 443 | the only public edge (WAF in front when `enable_waf`) |
| CloudFront VPC origins | platform host | 80 | web UI and API; security group admits only the CloudFront origin-facing prefix list |
| CloudFront VPC origins | engine host | 8080 | `/pulso/*` |
| platform, engine | core host | 8000 | Agent Core API; security group `sg_core` admits those two only |
| core host | llm-gateway (same host) | 8080 | published on the core host for the engine host only (security group), plus the internal compose network |
| core, platform, engine | RDS | 5432 | `sg_db` admits the three host groups only |
| hosts | S3, ECR, SSM, Secrets Manager, KMS, CloudWatch | 443 | S3 via the gateway endpoint, the rest via the NAT |
| hosts | LLM providers and package mirrors | 443 | via the NAT |
| you | hosts | SSM | `aws ssm start-session`; no inbound rule exists |

Host security groups allow no SSH. Core and the gateway are never exposed to CloudFront.

## What runs where

| Host | Services | Data volume |
|---|---|---|
| core | core-migrate (one-shot), core-runtime, core-exporter, llm-gateway | 20 GB gp3 at `/srv`, daily DLM snapshots, 3 kept |
| platform | support-platform-api, support-platform-web, proxy (Caddy) | 20 GB; SQLite of support-platform lives here |
| engine | pulso, proxy (Caddy); the data loader runs here by default (`engine_host_can_load`) | 40 GB |

Compose bundles are published to `engine/deploy/<workload>/` in the bucket and synced on every start by the `pulso-stack` systemd unit. Env files are rendered into tmpfs (`/run/pulso/env`) from the host's slice of the one secret and from SSM.

## Bucket prefixes and data classes

| Prefix | Class | Who may read | Who may write |
|---|---|---|---|
| `landing/` | PII in the clear (raw uploads) | loader (engine host role) and break-glass principals; reads only through the VPC S3 endpoint unless loader or break-glass | uploader principals (PUT only) |
| `lake/bronze/` | PII in the clear | loader and break-glass only | loader |
| `lake/silver/`, `lake/gold_masked/`, `lake/gold_analytics/` | masked or pseudonymised | engine host (gold zones), loader | loader |
| `engine/*` (`artifacts`, `evidence`, `reports`, `console`, `deploy`) | internal | engine host | engine host |
| `core/blobs/` | internal | core host | core host |
| `logs/` (90 days), `tmp/` (7 days) | internal | hosts | hosts |

Core and platform never read `landing/` or `lake/bronze/`: the identity policies do not grant it and the bucket policy denies it. See [security-model](security-model.md).

## Secrets and keys

One KMS key (rotation on) encrypts the bucket objects. One Secrets Manager secret holds every sensitive value (JSON, keys `<SERVICE>__<VAR>`, see [secrets-keys](secrets-keys.md)); each host role may read exactly that ARN. Non-secret configuration lives in SSM standard parameters, readable per workload prefix.

## Terraform modules

| Module | Builds |
|---|---|
| `hackathon_network` | VPC, subnets, NAT, security groups, S3 endpoint, private zone |
| `hackathon_data` | RDS, bucket, KMS key, secret, SSM skeleton, access policies |
| `hackathon_iam` | one role and profile per host, permissions boundary |
| `hackathon_compute` (x3) | EC2 host, data volume, DLM snapshots, compose bundle, DNS record |
| `hackathon_edge` | CloudFront, two VPC origins, WAF |
| `bootstrap` (separate root) | state bucket, ECR repositories; CloudTrail, budget and the CI role are off |

Longer module notes: [hackathon_network](../terraform/modules/hackathon_network/README.md), [hackathon_data](../terraform/modules/hackathon_data/README.md), [hackathon_edge](../terraform/modules/hackathon_edge/README.md), [hackathon_iam](../terraform/modules/hackathon_iam/README.md), and the compose bundles in [deploy/hackathon](../deploy/hackathon/README.md).

## free_plan profile (default for now)

Same three hosts, same bucket, same single secret; what differs (variable `profile`, `terraform/envs/hackathon`):

```
CloudFront (public origin, X-Origin-Verify) -> platform host :80 / engine host :8080   (public subnets, public IP, SG = CloudFront prefix list only)
platform, engine -> core host :8000 (agent-core runtime) and :5432 (Postgres container)   (sibling SGs only)
core host (m7i-flex.large): core-migrate, core-runtime, core-exporter, llm-gateway, postgres 16 (own EBS volume /srv/pgdata)
all hosts -> S3 via the gateway endpoint; ECR, SSM, model APIs via the public IP (outbound only, no NAT)
```

`profile = "prod"` restores the previous design: RDS in isolated subnets (`database_mode = "rds"`), private hosts behind one NAT gateway, CloudFront VPC origins, WAF. The toggles can be mixed (`database_mode`, `enable_nat`, `enable_waf`, `edge_enabled`, `enable_host_builder`, `db_volume_size_gb`), and `terraform output profile_effective` prints what was resolved. Decision record: [ADR 0008](adr/0008-hackathon-free-plan-profile.md).
