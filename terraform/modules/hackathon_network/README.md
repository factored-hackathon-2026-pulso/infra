# hackathon_network

Network for the three-host hackathon profile (ADR 0007): one VPC, two AZs; public subnets (NAT only); private
subnets for the hosts (no public IP); isolated db subnets (no default route); exactly one NAT gateway in AZ a
(about 32 USD/month plus data; an AZ-a outage cuts egress); a free S3 gateway endpoint on the private route table
(keeps S3 traffic off the NAT); a private Route 53 zone (`zone_name`, default `pulso.internal`) whose records the
compute lane creates.

Security groups (no SSH anywhere; use SSM Session Manager):

| SG | Ingress | Egress |
| --- | --- | --- |
| `sg_platform` | 80 from CloudFront prefix list (and optionally the VPC-origin SG, `admin_cidr`) | 443, 5432 to db, 8000 to core, DNS |
| `sg_engine` | 8080 from the same sources | 443, 5432 to db, 8000 to core, DNS |
| `sg_core` | 8000 from engine and platform only | 443, 5432 to db, DNS |
| `sg_db` | 5432 from the three hosts only | none |

Flow logs: `enable_flow_logs` (default false; costs money).

Outputs: `vpc_id`, `public_subnet_ids`, `private_subnet_ids`, `db_subnet_ids`, `sg_platform_id`, `sg_core_id`,
`sg_engine_id`, `sg_db_id`, `sg_host_id` (alias of `sg_platform_id`), `s3_gateway_endpoint_id`, `nat_gateway_id`,
`zone_id`, `zone_name`.

Test: `terraform init -backend=false && terraform test` (mock provider, no credentials).
