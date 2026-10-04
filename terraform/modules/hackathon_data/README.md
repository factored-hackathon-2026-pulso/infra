# hackathon_data

Cheap, single-host data profile for a brand-new account: one RDS PostgreSQL 16, one S3 bucket, one KMS key, one Secrets
Manager secret, a small SSM config skeleton. Not scalable on purpose. Verified offline only (mock providers).

Inputs (contract): `vpc_id`, `db_subnet_ids`, `sg_db_id`, `name_prefix`, `region`. Outputs (contract): `db_endpoint`,
`db_port`, `db_master_secret_ssm_name` (the NAME of the Secrets Manager secret, kept for the interface; key
`RDS_MASTER_PASSWORD`), `bucket_name`, `bucket_arn`, `ssm_prefix`, `ssm_parameter_arn_prefix`. Added: `secret_arn`,
`kms_key_arn`, `uploader_policy_json`, `loader_policy_json`, `host_policy_json`. No password is ever an output.
See `docs/db-bootstrap.md` and `docs/secrets-keys.md`.

## Bucket layout (`<name_prefix>-data-<account id>`)

| Prefix | Content | Class | Access |
|---|---|---|---|
| `landing/` | E0 and CSV/Parquet uploaded by the human | PII in clear | PUT: uploader; GET: loader and break-glass, only through the S3 VPC endpoint |
| `lake/bronze/` | faithful copy of sources (data pipeline) | PII in clear | loader and break-glass only |
| `lake/silver/`, `lake/gold_masked/`, `lake/gold_analytics/` | pipeline outputs | masked / pseudonymised | host reads gold_masked and gold_analytics; loader writes |
| `engine/artifacts`, `evidence`, `reports`, `console` | engine outputs | internal | host read/write |
| `core/blobs/` | Agent Core blobs (`AGENTCORE_BLOB_BUCKET`) | internal | host read/write |
| `logs/` | reserved for CloudFront logs and similar | internal | expires after 90 days |
| `tmp/` | scratch | any | expires after 7 days |

Controls: BucketOwnerEnforced, all public access blocked, versioning, default SSE-KMS with one customer-managed key
(rotation on, bucket key on), TLS-only Deny, noncurrent versions expire after 30 days, incomplete multipart uploads abort
after 7. The bucket policy contains Deny statements only (it cannot widen access); grants are identity policies from the
`*_policy_json` outputs, attached by the iam lane. Optional: `bronze_glacier_ir_days`, `enable_eventbridge` (off).

Caveats. The VPC-endpoint Deny applies to reads of `landing/` (the human uploads from outside, PUT only). Principal lists
fail closed: with empty `loader_role_arns` and `break_glass_principal_arns` nobody can read `landing/` or `lake/bronze/`.
S3 server access logging is not enabled: it cannot deliver to an SSE-KMS bucket. Evaluator labels (`bronze_eval/` in the
data lake) must not be written under `lake/` of this bucket: the loader policy could read them.

## Relation to `data_lake` and `data_pipeline` (ADR 0006)

Those modules are unchanged. `data_lake` creates its own bucket with per-zone Deny policies, `bronze/`, `bronze_eval/`
and `publish/`. The hackathon profile does not instantiate `data_lake`; the pipeline runs with
`PIPELINE_ROOT=s3://<bucket>/lake` (SSM `/pulso/engine/PIPELINE_ROOT`), with `loader_policy_json` and the host policy as
its roles. Zone separation here is coarser (PII versus masked) than the five-zone model; the production path remains
`data_lake`/`data_pipeline` with their own bucket.

## Estimated monthly cost (us-east-1, approximate, no free tier)

| Component | USD |
|---|---|
| RDS db.t4g.micro single-AZ (free tier may cover 750 h for 12 months on eligible accounts) | ~12 |
| gp3 20 GB | ~2.3 |
| Backups (inside the free allowance equal to storage) | ~0 |
| KMS customer key | 1.00 plus requests (bucket key keeps them tiny) |
| Secrets Manager, one secret | 0.40 |
| SSM standard parameters | 0 |
| S3 | cents for demo data |
| ElastiCache (`enable_redis`, not implemented) | ~12 if ever added |
| Total | ~16 |
