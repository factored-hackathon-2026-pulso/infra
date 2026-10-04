# Modification guide

How the Terraform is organised and how to change it safely. Rules of the repo are in `AGENTS.md`; the short version: small slices, tests first, no apply by agents, no secrets in Git.

## Layout

| Path | What it is |
|---|---|
| `terraform/bootstrap` | separate root, local state, run once per account: state bucket (`pulso-prod-tfstate-<account id>` unless `state_bucket_name` is set), ECR repositories, account S3 public-access block. Off by default: CloudTrail, budget, GitHub OIDC role |
| `terraform/envs/hackathon` | the one prod composition, remote state in the bootstrap bucket (`backend "s3" {}` placeholder, config injected by `scripts/aws-prod.ps1`) |
| `terraform/modules/hackathon_*` | the five modules the composition calls (`hackathon_network`, `hackathon_data`, `hackathon_iam`, `hackathon_compute` x3, `hackathon_edge`) |
| `terraform/modules/*` (others), `terraform/envs/staging`, `terraform/envs/prod` | older production-path material (ECS, data lake, pipeline); not part of the single-account prod deployment |
| `deploy/hackathon/<workload>/` | compose bundles and Caddyfiles published to `engine/deploy/<workload>/` |
| `scripts/` | `aws-prod.ps1` (operator helper), `release-engine.ps1` (image build/push), `aws_plan_review.py` (offline checker) |
| `tests/` | Python contract tests (unittest style, also runnable with pytest) |

## Module contracts

Interface names between modules (the composition in `main.tf` is the single place they meet):

| Producer | Outputs used |
|---|---|
| `module.network` | `vpc_id`, `private_subnet_ids`, `db_subnet_ids`, `sg_core_id`, `sg_platform_id`, `sg_engine_id`, `sg_db_id`, `s3_gateway_endpoint_id`, `zone_id` |
| `module.data` | `bucket_name`, `secret_arn`, `kms_key_arn`, `ssm_prefix`, `db_endpoint` |
| `module.iam` | `instance_profile_name_<workload>`, `instance_role_arn_<workload>` |
| `module.compute_core`, `module.compute_platform`, `module.compute_engine` | `instance_id`, `instance_arn`, `private_dns`, `private_zone_record` |
| `module.edge` | `cloudfront_domain_name`, `cloudfront_distribution_id` |

A compute module needs: workload name (`core`, `platform`, `engine`), subnet, security groups, instance profile, zone, bucket, secret ARN, KMS ARN, ECR registry, the `images` map for that workload and a bundle directory. The bundle contract: `compose.yaml` using `${<KEY>_IMAGE}` variables (key is the upper-cased `images` key), optional `Caddyfile`; env comes from the secret slice and SSM.

## Variable reference

`terraform/envs/hackathon` (all optional except `images`; example values in [prod.tfvars.example](../terraform/envs/hackathon/prod.tfvars.example)):

| Variable | Default | Meaning |
|---|---|---|
| `region` | `us-east-1` | stack region |
| `cloudfront_waf_region` | `us-east-1` | region of the alias provider for the CloudFront WAF (must be us-east-1) |
| `environment` | `prod` | tag value; there is one environment |
| `name_prefix` | `pulso-prod` | prefix of every resource name |
| `enabled` | all true | per-host kill switch |
| `instance_types` | `t3.small` each | EC2 type per host |
| `data_volume_size_gb` | 20, 20, 40 | data volume per host |
| `protect_data_volume` | `true` | `prevent_destroy` volume variant |
| `enable_cloudwatch_agent` | `false` | ship docker logs to CloudWatch |
| `ecr_registry_url` | derived | `<account id>.dkr.ecr.<region>.amazonaws.com` |
| `images` | required | digest-pinned full image refs per host |
| `enable_waf` | `true` | WAFv2 on the distribution |
| `engine_host_can_load` | `true` | loader policy on the engine host role |
| `loader_role_arns` | `[]` | extra loader roles |
| `uploader_principal_arns` | `[]` (account users and root) | may PUT to `landing/` |
| `break_glass_principal_arns` | `[]` (account users and root) | exempt from the PII deny |
| `db_deletion_protection` | `true` | RDS deletion protection |
| `db_skip_final_snapshot` | `false` | skip the final RDS snapshot on destroy |

`terraform/bootstrap` (all optional): `aws_region` (`us-east-1`), `state_bucket_name` (null, derived), `state_key`, `tags`, `budget_alert_email` (empty: no budget), `monthly_budget_usd`, `account_alias`, `cloudtrail_enabled` (`false`), `github_org` and `github_repo` and `github_allowed_refs` (empty: no OIDC role), `ecr_repository_prefix` (`pulso-prod`), `ecr_repositories`.

## State backend and lock

State is S3 with native locking (`use_lockfile = true`, Terraform 1.10 or newer, no DynamoDB). `scripts/aws-prod.ps1` writes `.scratch/aws-prod/backend.hcl` (ignored by Git) and runs `terraform init -reconfigure -backend-config=...`. Key: `pulso/prod/hackathon/terraform.tfstate`. Bootstrap's own state is local by default; the already applied account keeps it in the state bucket at key `bootstrap/terraform.tfstate`. Bootstrap defaults (`ecr_repository_prefix` `pulso-prod`, bucket `pulso-prod-tfstate-<account id>`) match what was applied, so a plan against that state must show no changes. A stuck lock: [troubleshooting](troubleshooting.md#state-lock-stuck).

## Add or change a module with TDD

1. Write a `*.tftest.hcl` next to the module with `mock_provider "aws" {}` (see `terraform/modules/hackathon_iam/hackathon_iam.tftest.hcl`): one failing `run` block asserting the observable behaviour (policy statements, resource counts, outputs). Commit it RED.
2. Implement the smallest change, run it green, commit GREEN. Every commit message ends with the team trailer the repo uses.
3. Commands (one terraform process at a time; on Windows set `$env:TF_PLUGIN_CACHE_DIR = 'D:/tf-plugin-cache'` so providers are not re-downloaded and parallel runs do not corrupt the cache):
   ```powershell
   terraform -chdir=terraform/modules/<module> init -backend=false -input=false
   terraform -chdir=terraform/modules/<module> test
   terraform -chdir=terraform/envs/hackathon validate
   terraform fmt -check -recursive terraform
   python -m unittest discover -s tests -v
   python scripts/aws_plan_review.py
   Invoke-Pester scripts/tests
   ```
4. The plan-review checker (`scripts/aws_plan_review.py`) fails on: hard-coded account ids, region literals, wildcard actions or principals (outside Deny), `AdministratorAccess`, public DB, open ingress, committed key material, and expansion switches that default on. Region literals are allowed only as the default of `region`, `aws_region` and `cloudfront_waf_region` (us-east-1: single-region prod, and CloudFront WAF exists only there) and `dataset_region` (us-east-2, where the external challenge dataset lives).
5. CI (`.github/workflows/ci.yml`): contract suite (`python -m unittest discover -s tests`, which includes the doc-consistency test), `terraform fmt -check`, init/validate of both roots, `terraform test` of every module listed there. Add a new module to the loop in that file.
6. Keep docs in the same commit: `tests/test_docs_consistency.py` fails when a documented subcommand, flag, `var.<name>`, module or relative link does not exist, and when a variable of the two prod roots is not mentioned anywhere in the docs.

## Naming and tagging

Resource names start with `name_prefix` (`pulso-prod-...`); roles and policies use `name_prefix` too. Every resource gets `ManagedBy = terraform`, `Service = pulso-hackathon`, `Environment = <environment>`; hosts add `Workload`. Snapshot policy targets the `Snapshot` tag. SSM paths: `/pulso/<workload>/<service>/<VAR>`. Secret: `<name_prefix>/hackathon`. Bucket: `<name_prefix>-data-<account id>`.

## Never commit

Secret values, access keys, `prod.tfvars` or any `*.tfvars` (only `*.tfvars.example`), `backend.hcl`, state and plan files, account ids, personal emails, data or logs. `.gitignore` covers the files; the checker and doc test catch ids and keys in code and docs.

## Serial runs and Windows notes

Run one terraform process at a time (parallel runs fight over the provider cache and lock files). Use `TF_PLUGIN_CACHE_DIR`; if `init` hangs for minutes, kill it and retry once. The aws provider takes a long time to start the first time on Windows: see [troubleshooting](troubleshooting.md#provider-start-timeout).
