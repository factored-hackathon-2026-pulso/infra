# Costs

> **Profile.** The table below is the `prod` profile (RDS, NAT, WAF). The default profile for now is `free_plan`, priced in [free_plan profile](#free_plan-profile). Switch with `profile = "prod"` in `prod.tfvars`.

Approximate USD per month, us-east-1, on-demand, steady state, demo traffic and data. Estimates for planning, not a quote: check the AWS pricing pages and the Billing console. There is no budget alarm (by decision): look at Billing > Cost Explorer yourself, weekly.

| Resource | Free tier | Estimate |
|---|---|---|
| VPC, subnets, security groups, route tables, S3 gateway endpoint, IAM, DLM, Route 53 records | free | 0 |
| NAT gateway (1) + its public IPv4 + data processed | no | ~37 |
| 3 x EC2 t3.small (on-demand) | 750 h of t2/t3.micro only if the account is in its first 12 months, and t3.small is not t3.micro | ~46 |
| EBS gp3: 3 x 20 GB root + 80 GB data, daily snapshots (3 kept) | 30 GB first 12 months | ~12 |
| RDS PostgreSQL db.t4g.micro single-AZ, 20 GB, 7-day backups | 750 h and 20 GB in the first 12 months on eligible accounts | ~15 (0 inside free tier) |
| KMS customer key | no | 1 |
| Secrets Manager (1 secret) | 30-day trial | 0.40 |
| SSM Parameter Store standard parameters | free | 0 |
| Route 53 private hosted zone | no | 0.50 |
| CloudFront (default domain) | 1 TB and 10 M requests per month, always free | 0 |
| WAFv2 (1 web ACL + 3 rules + requests) | no | ~8 |
| S3 (demo data), ECR (6 repositories), CloudWatch logs | small free allowances | ~1-3 |
| Remote state bucket | small | ~0 |
| **Total** | | **about 120 with WAF, 112 without** |

CloudTrail (management events) and the budget are off by default; CloudTrail's first copy of management events is free (S3 storage billed).

## Levers

- Stop hosts: `enabled = { core = false, ... }` in `prod.tfvars` removes the EC2 compute charge (about 15 per host); volumes, snapshots, RDS and NAT keep billing.
- `enable_waf = false` saves about 8.
- Smaller or fewer volumes: `data_volume_size_gb`; shorter RDS backup retention in the module variable `db_backup_retention_days` of `hackathon_data` (default 7).
- NAT is the biggest fixed cost and cannot be paused without losing egress (image pulls, LLM providers, SSM). A full teardown (`destroy`) is the only way to stop it; see [operations](operations.md#teardown).
- Stopped RDS restarts itself after 7 days: do not rely on stopping it.

## free_plan profile

The human's account is on the AWS Free Plan: it refuses instance types outside the Free Tier eligible list (`c7i-flex.large`, `m7i-flex.large`, `t3.micro`, `t3.small`, `t4g.micro`, `t4g.small`, `t8i.micro`, `t8i.small`) and may refuse other services at apply time. The profile (`profile = "free_plan"`, variable `profile`) changes what costs money:

| Resource | prod | free_plan |
|---|---|---|
| NAT gateway + data processing | ~37 | **0** (`enable_nat` null = off: hosts in public subnets with public IPs, outbound only) |
| Public IPv4 addresses (3 hosts, 0.005 USD per hour each) | 0 | ~11 (the NAT EIP in prod is already inside the NAT line) |
| EC2 | 3 x t3.small ~46 | core `m7i-flex.large` (8 GB, also runs Postgres) + engine `m7i-flex.large` when the loader is on (the largest Free Plan type; else `t3.small`) + platform `t3.small`; flex types are billed less than their m7i/c7i siblings, check the pricing page |
| RDS db.t4g.micro | ~15 | **0** (`database_mode = "container"`: Postgres 16 on the core host) |
| Postgres EBS volume (`db_volume_size_gb`, default 30) + daily snapshots | 0 | ~3 |
| WAFv2 | ~8 | **0** (`enable_waf` null = off) |
| CodeBuild | small | `BUILD_GENERAL1_SMALL`, per build minute; the fallback `images -Builder host` costs nothing extra |

Free Plan credits and the 6-month window apply on top; they are not modelled here. Treat every number as an estimate until the first Cost Explorer week. Levers: `enabled = { core = false, ... }` stops a host (the Postgres volume and snapshots keep billing), `edge_enabled = false` removes CloudFront, `db_volume_size_gb` shrinks the database volume (before first apply only).
