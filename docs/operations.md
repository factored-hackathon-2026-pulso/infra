# Operations (day 2)

All commands run from the repo root in PowerShell 7 with the profile `pulso-prod` (see [quickstart](aws-prod-quickstart.md)). Terraform values live in the uncommitted `terraform/envs/hackathon/prod.tfvars`. Rule of this repo: no apply without a saved plan you read; `scripts/aws-prod.ps1` enforces it. Variable reference: [modification-guide](modification-guide.md#variable-reference).

## Bring up from zero

`.\scripts\aws-prod.ps1 check` > `bootstrap-plan` > `bootstrap-apply` > `images` > `plan` > `apply`, then secrets, DB bootstrap, first start, upload (all in the quickstart). The only manual order dependency: DB roles and secrets exist before the stacks can become healthy.

## First start order and per-host start/stop

Start order the first time: core, then platform and engine (they call core at `http://core.pulso.internal:8000`).
```powershell
aws ssm start-session --profile pulso-prod --region us-east-1 --target <instance id>
# on the host
sudo systemctl status pulso-stack
sudo systemctl restart pulso-stack
docker compose -p pulso ps
```
Kill switch per host (stops the EC2 instance; volume and snapshots stay, compute billing stops). In `prod.tfvars`:
```hcl
enabled = { core = true, platform = true, engine = false }
```
then `.\scripts\aws-prod.ps1 plan -Profile pulso-prod` and `apply -Profile pulso-prod`. Set it back to `true` to start; the host boots `pulso-stack` by itself.

## Deploy a new image digest, roll back

1. Build and push: `.\scripts\aws-prod.ps1 images -Profile pulso-prod -PulsoDir <dir> -AgentCoreDir <dir> -LlmGatewayDir <dir> -SupportPlatformDir <dir> -CaddyUpstreamDigest sha256:<64 hex>` (rewrites only the `images` block of `prod.tfvars`; images are digest-pinned, tags are never used). To rebuild a single image use `scripts/release-engine.ps1` directly and edit the digest in `prod.tfvars` by hand.
2. `plan` (the env file changes in S3, the instances do not change), read it, `apply`.
3. On each affected host: `sudo systemctl restart pulso-stack` (syncs the bundle, re-renders env, pulls, `docker compose up -d`). Core first if core changed.
4. Roll back: put the previous digest back in `prod.tfvars` (old digests stay in ECR), `plan`, `apply`, restart `pulso-stack`. Keep the previous `prod.tfvars` copy outside Git.

## Change instance type or volume size

`instance_types` and `data_volume_size_gb` in `prod.tfvars`. An instance type change stops and starts the host (short outage; the data volume stays). Growing a volume is online for EBS, then on the host run `sudo xfs_growfs /srv` (or `resize2fs` if the filesystem is ext4). Shrinking is not supported: restore from a snapshot into a smaller volume instead.

## Add a service to a host, or a new host

Service on an existing host: add it to `deploy/hackathon/<workload>/compose.yaml` (the bundle in [deploy/hackathon](../deploy/hackathon/README.md)); if it needs an image add a key to the `images` object for that host in `terraform/envs/hackathon/variables.tf` and in `prod.tfvars.example` (images are `<registry>/<repo>@sha256:...`, ECR pull rights derive from them); create the ECR repo in `ecr_repositories` of bootstrap; give it env from the secret (next sections); `plan`, `apply`, restart `pulso-stack`.

New host: copy a `module "compute_<name>"` block in `terraform/envs/hackathon/main.tf` (module `hackathon_compute`, see [modification-guide](modification-guide.md#module-contracts)), add its workload to `locals.workloads` in `terraform/modules/hackathon_iam/main.tf` and its security group in `terraform/modules/hackathon_network`, add a bundle directory `deploy/hackathon/<name>/`, and extend `enabled`, `instance_types`, `data_volume_size_gb`. Write the tests first.

## Secrets: rotate a value, add a key

- Rotate: edit the key in the secret `pulso-prod/hackathon` (console, or `put-secret-value`), then `sudo systemctl restart pulso-stack` on every host whose services use it (env files are rendered at start). Terraform ignores later value changes.
- Add a key: name it `<SERVICE>__<VAR>` (SERVICE is `COMMON`, `CORE`, `GATEWAY`, `SUPPORT` or `PULSO`), document it in [secrets-keys](secrets-keys.md), add the matching compose `environment` or `env_file` entry for the service in `deploy/hackathon/<workload>/compose.yaml`, set the value in the secret, publish (`apply`) and restart. The prefix chooses which host renders it; it is not an access boundary ([security-model](security-model.md)).
- Database passwords (`DB_PASSWORD_*`, `RDS_MASTER_PASSWORD`) are not rendered to env files; changing one also needs the SQL role change and the DSN keys updated ([db-bootstrap](db-bootstrap.md)).

## Shell, logs, health

- Shell: Session Manager only. `aws ssm start-session --profile pulso-prod --region us-east-1 --target <instance id>`; ids from `.\scripts\aws-prod.ps1 status -Profile pulso-prod`. Needs the Session Manager plugin for the AWS CLI.
- Logs: `docker compose -p pulso logs -f <service>` on the host; boot log `sudo journalctl -u pulso-stack -b` and `/var/log/cloud-init-output.log`; with `enable_cloudwatch_agent = true` also CloudWatch group `/pulso-prod/docker`.
- Health: `.\scripts\aws-prod.ps1 status -Profile pulso-prod` prints instances and, over SSM, `pulso-stack` state and container status.

## Database access, bootstrap, restore

- Access: from a host shell only (the DB is in isolated subnets). The master password is the `RDS_MASTER_PASSWORD` key; export it from the secret into `PGPASSWORD` on the host, never on a command line. `psql` 15 or newer is required for the scripts.
- Bootstrap: [db-bootstrap](db-bootstrap.md).
- Restore from RDS backup: backups are on (7 days). Console > RDS > Automated backups > Restore to point in time creates a NEW instance; point the DSN keys at its endpoint, restart `pulso-stack`, then reconcile Terraform (`terraform import` the new instance after removing the old, or restore data into the existing one with `pg_dump`/`pg_restore`). Do not let Terraform destroy the original before the new one is verified.
- Restore a data volume from a DLM snapshot (daily, last 3): stop the host (`enabled = false`), create a volume from the snapshot in the same AZ (console > EC2 > Snapshots > Create volume), swap it with the Terraform-managed volume by detaching and attaching at `/dev/sdf`, `terraform state rm` the old volume resource and `terraform import` the new one, then start the host. Practise this once before you need it.

## Rotate KMS and IAM

- KMS: key rotation is on (annual, automatic, transparent). Never delete the key (30-day window): objects become unreadable.
- IAM: host roles are managed by Terraform; there is nothing to rotate for them (instance profiles issue short-lived credentials). Rotate your own admin access key every time you create one: create new, run `aws configure --profile pulso-prod`, delete the old.

## Upload and load data (landing > loader > lake > engine)

1. `.\scripts\aws-prod.ps1 upload -Profile pulso-prod -Path <dir> -Dataset <name> -DryRun`, then without `-DryRun`. Objects go to `landing/<name>/` with SSE-KMS. By default every IAM user and the root of the account may upload (`uploader_principal_arns` empty), because the bucket policy is deny-only and your admin identity policy allows the call.
2. The engine host role carries the loader policy while `engine_host_can_load` is true: it reads `landing/` and `lake/`, writes `lake/`. Run the data pipeline on the engine host (SSM shell) with `PIPELINE_ROOT=s3://<bucket>/lake` (SSM parameter) to produce `lake/bronze`, `silver`, `gold_masked`, `gold_analytics`.
3. The engine reads only `lake/gold_masked/` and `lake/gold_analytics/` at runtime; core and platform never touch `landing/` or `lake/bronze/`.
4. To use a dedicated loader instead, set `engine_host_can_load = false` and list its role in `loader_role_arns`.

## Re-point CloudFront origins

Origins are the platform and engine instances (`platform_origin_arn`, `engine_origin_arn` of module `hackathon_edge`, wired in `main.tf` from the compute outputs). Replacing an instance (for example a changed `user_data`) re-creates the VPC origin on the next `apply`. To use an internal load balancer instead, pass its ARN as the origin ARN in `main.tf`. See [troubleshooting](troubleshooting.md#cloudfront-vpc-origin).

## Teardown

Order and protections, all through `scripts/aws-prod.ps1`:
1. Stop traffic: `enabled` all false (optional, shortens the outage window).
2. In `prod.tfvars` set `protect_data_volume = false`, `db_deletion_protection = false`, and `db_skip_final_snapshot = true` only if you accept losing the final RDS snapshot. `apply` this change first.
3. Empty the data bucket if it still holds objects (versioned: delete versions too). It is the only thing Terraform will not delete for you.
4. `.\scripts\aws-prod.ps1 destroy-plan -Profile pulso-prod`, read it, then `.\scripts\aws-prod.ps1 destroy -Profile pulso-prod` and type `DESTROY`.
5. The bootstrap state bucket (`pulso-prod-tfstate-<account id>`) and ECR repositories are destroyed from `terraform/bootstrap` only after step 4, with the same plan-then-confirm flow, after emptying the buckets. Keep a copy of bootstrap's local state until then.
6. Delete the root access key (see [quickstart](aws-prod-quickstart.md) step 12).

## Cost levers

Stop hosts (`enabled`), `enable_waf = false`, smaller `instance_types`, shorter RDS backup retention. The NAT gateway (about a third of the bill) cannot be paused without losing egress; see [costs](costs.md).
