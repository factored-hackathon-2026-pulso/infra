# Hackathon foundations

One integrated branch (`claude/hackathon-foundations`) of the cheap, private, three-host AWS profile (ADR 0007). Nothing here was applied:
everything is verified offline (mock providers, `terraform validate`, `terraform test`). Apply only with your explicit authorization.

## Architecture

```
 viewer --HTTPS--> CloudFront (+ WAF, us-east-1 alias)
                     |  VPC origin (HTTP, AWS network)         /pulso/* -> engine, everything else -> platform
        +------------+-------------------------------------------------------------+
        | VPC 10.20.0.0/16, 2 AZs                                                   |
        |  public subnets : NAT gateway (single, AZ a)                              |
        |  private subnets: core host :8000   platform host :80   engine host :8080 |
        |                   (EC2, no public IP, no SSH, SSM Session Manager only)   |
        |  db subnets     : RDS PostgreSQL 16 single-AZ (5432 from the 3 hosts)     |
        |  S3 gateway endpoint; Route 53 private zone: core|platform|engine.<zone> |
        +---------------------------------------------------------------------------+
 S3 data bucket (SSE-KMS, deny-only bucket policy) | 1 Secrets Manager secret | SSM /pulso/<workload>/<svc>/<VAR> | ECR
```

| Module | Purpose | Needs |
|---|---|---|
| `hackathon_network` | VPC, subnets, NAT, SGs per workload, S3 endpoint, private zone | region, name, tags |
| `hackathon_data` | RDS, bucket, KMS, secret, SSM skeleton, access policies | network ids and SG, region |
| `hackathon_iam` | one role + profile per host, deny boundary | bucket name, secret ARN, KMS ARN, SSM prefix, ECR ARNs (derived from `images`) |
| `hackathon_compute` x3 | EC2, data volume, daily snapshots, compose bundle, DNS record | network, iam, data outputs, ECR registry, digest-pinned `images` |
| `hackathon_edge` | CloudFront, two VPC origins, WAF | instance ARNs and private DNS names, aliased us-east-1 provider |
| `engine_task` | ECS task alternative (pulso + core-runtime sidecar) | NOT wired: unwired alternative to the three EC2 hosts |
| `bootstrap` | state bucket, budget, CloudTrail, OIDC plan role, ECR repos | run first, separately |

`data_lake` and `data_pipeline` are untouched (production path).

## Interfaces reconciled in the composition

- IAM per host: exactly the one secret (`GetSecretValue`), `kms:Decrypt`/`GenerateDataKey` on the data key, `ssm:GetParameter*` on
  `/pulso/<workload>/*`, S3 `engine/deploy/<workload>/*` (list and get), its own prefixes (core: `core/blobs`; engine: `engine/`, read
  `lake/gold_masked`, `lake/gold_analytics`), ECR pull for its own repositories, logs under `/<name>/*`.
- Bucket policy is deny-only (TLS, PII prefixes only for loader/break-glass, `landing/` reads only via the S3 endpoint). Host roles are
  allowed by identity policy and never touch `landing/` or `lake/bronze/`. Lifecycle expires only `tmp/` and `logs/` (test-guarded), so
  `engine/deploy/` is never expired.
- Secret keys are `<SERVICE>__<VAR>` (CORE, GATEWAY, SUPPORT, PULSO; COMMON optional); `DB_PASSWORD_*` and `RDS_MASTER_PASSWORD` are unprefixed.
- SSM parameters are `/pulso/<workload>/<service>/<VAR>`; the start script reads `<prefix>/<workload>/<service>`.
- Engine proxy listens on 8080 (matches the network rule and the edge default). Compute log group is `/<name_prefix>/docker`.
- Route 53 records are created by compute (`<workload>.<zone>` A, TTL 60), in the zone from network.
- ECR: bootstrap creates `<prefix>/{pulso-engine,core-runtime,llm-gateway,support-platform-api,support-platform-web,caddy}`; the
  `images` values must be `<prefix>/<repo>@sha256:...` (the host ECR pull grants are derived from them).

## Apply order (single `terraform apply` of `envs/hackathon`, Terraform orders it)

1. `terraform/bootstrap` (runbook `docs/runbook-new-account.md`), push images (`scripts/release-engine.ps1`, mirror Caddy by digest).
2. `envs/hackathon`: network, data, iam, compute x3, edge.
3. Set the secret values and SSM placeholders out of band; DB bootstrap (`docs/db-bootstrap.md`); start order core, then platform and engine
   (`docs/hackathon-deploy.md`).

## Cost (us-east-1, approximate USD per month, no free tier)

| Item | Free? | Estimate |
|---|---|---|
| VPC, subnets, SGs, S3 gateway endpoint, IAM, SSM standard parameters, DLM, CloudFront (first 1 TB/10 M requests) | free | 0 |
| NAT gateway (single) + its IPv4 + data | paid | ~37 |
| Route 53 private zone | paid | 0.5 |
| 3 x EC2 t3.small | paid | ~46 |
| EBS: 3 x 20 GB root + 80 GB data gp3, snapshots | paid | ~12 |
| RDS db.t4g.micro single-AZ + 20 GB (free tier may cover 12 months) | paid | ~15 |
| KMS key + 1 secret | paid | ~1.4 |
| WAF (ACL + 3 rules, `enable_waf=false` removes it) | paid | ~8 |
| Total | | ~120 (about 112 without WAF); kill switch `enabled` stops EC2 only |

## What the human must provide

AWS profile name (never in the repo), region (`region`, no default), `cloudfront_waf_region` (N. Virginia), alert email (bootstrap
budget), domain: none (CloudFront default domain and certificate), `uploader_principal_arns` (who uploads to `landing/`),
`loader_role_arns` (pipeline role that reads `landing/` and `lake/bronze/`), `break_glass_principal_arns`, ECR `images` digests and
`ecr_registry_url`, GitHub org/repo for OIDC (optional), then the secret values.

## Open risks (unverified until the first apply)

- CloudFront VPC origin to a private EC2 instance: accepted only at first apply; the origin-facing prefix list is on the host SGs and
  `cloudfront_vpc_origin_sg_id` can be added after the first origin exists.
- HTTP to origin (`http-only`) inside the VPC origin; `https-only` needs a certificate on the Caddy proxies. The `X-Origin-Verify` header is
  supported by the edge module but unset and not checked by Caddy.
- Caddy image must be mirrored to ECR by digest; the docker compose plugin is downloaded from GitHub without a checksum in user_data.
- One secret is readable by all three hosts (the key prefix is not an access boundary); the random RDS master password is in Terraform state
  (state bucket is encrypted and private). The repo test that forbids `aws_secretsmanager_secret_version` has a documented exception for `hackathon_data`.
- Engine role can write under `engine/`, including `engine/deploy/` (its own bundle).
- The mock provider does not echo nested CloudFront policy ids and `terraform validate` of `hackathon_edge` alone fails (needs the alias): both
  are covered through the env composition; wiring of policy ids is confirmed only at first apply.
- Secret key names for providers and bridge signers are assumptions to confirm with their owning teams.
- Pre-existing, left alone: plan-review `hardcoded-region` on `modules/data_pipeline/variables.tf:104` (fails on main too).
