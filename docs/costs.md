# Costs

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
