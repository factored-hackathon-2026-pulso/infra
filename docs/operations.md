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

A new digest never needs a Terraform apply and never replaces an instance: digests live in SSM Parameter Store (`/pulso/<workload>/images/<key>`), Terraform only seeds them. Full guide for service teams, with the IAM they need, per-service notes, a worked example and troubleshooting: [service-deployment](service-deployment.md).

1. Build and push: `.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service <name> -SourceDir <dir>` builds in AWS CodeBuild (no local Docker) and prints the `repo@sha256:` digest (`-AgentCoreDir` for agent-core, `-MirrorImage` for caddy). Without `-Service` the older local flow remains: `.\scripts\aws-prod.ps1 images -Profile pulso-prod -PulsoDir <dir> -AgentCoreDir <dir> -LlmGatewayDir <dir> -SupportPlatformDir <dir> -CaddyUpstreamDigest sha256:<64 hex>` (rewrites only the `images` block of `prod.tfvars`).
2. Deploy: `.\scripts\aws-prod.ps1 deploy -Profile pulso-prod -Service <name> -FromBuild <build id> -Wait` (or `-Digest sha256:<64 hex>`). It checks the digest in ECR, writes the SSM parameter, runs the document `pulso-deploy-<workload>` on the host (pull, `up -d`, wait healthy) and restores the previous digests by itself when the new ones are unhealthy. Type `DEPLOY` (or `-Yes`).
3. Roll back: `.\scripts\aws-prod.ps1 deploy -Profile pulso-prod -Service <name> -Rollback -Wait`.
4. `prod.tfvars` is only the seed for the FIRST apply and for a rebuilt host: after deployments the SSM parameters are the truth (Terraform ignores their value). A later `plan` shows no digest change even if `prod.tfvars` is older.

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
2. Loading is automatic with `auto_loader_enabled` ([auto-loader](auto-loader.md)): after the upload, write `engine/inbox/READY.json`; a timer on the engine host assumes the loader role and runs the data pipeline (`lake/bronze`, `silver`, `gold_*`, `publish/`). The engine host role itself carries no loader policy (`engine_host_can_load = false`, the default).
3. The engine reads only `lake/gold_masked/` and `lake/gold_analytics/` at runtime; core and platform never touch `landing/` or `lake/bronze/`.
4. To use your own loader role instead, list it in `loader_role_arns`. `engine_host_can_load = true` gives the engine host PII access directly and is not recommended.

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

## Apply in stages (free_plan)

On a Free Plan account any service can be refused at apply time, and an apply stops at the first refusal while the rest of the plan is partly applied. Apply in small steps, one saved plan each, and read the error before the next one. Order, with the `-target` arguments (plans are produced with `scripts/aws-prod.ps1 plan`; add `-target` through the stage options only if you run terraform by hand):

1. **network**: `module.network` (VPC, subnets, security groups, S3 endpoint, private zone). No NAT in free_plan.
2. **data**: `module.data` and `module.iam` (bucket, KMS, the one secret, SSM parameters, instance roles). No RDS in container mode. Set the role passwords in the secret now (`DB__DB_PASSWORD_*` keys, not `CHANGE_ME`): the Postgres init refuses placeholders.
3. **builder**: `plan -Stage builder` then apply (CodeBuild projects, SMALL compute). Build the images (`images -Service ...`); if a Rust build runs out of memory use `-Builder host` after stage 4 (the core host must exist).
4. **compute**: `module.compute_core`, `module.compute_platform`, `module.compute_engine` (hosts, EBS volumes, DLM). If `m7i-flex.large` is refused the message says so; change `instance_types` to an eligible type and re-plan.
5. **edge**: the rest (`module.edge`: CloudFront, WAF if enabled). `edge_enabled = false` skips it; test the hosts through SSM first.

Error messages and what they mean are in [troubleshooting](troubleshooting.md#free-plan-errors-at-apply).

## Image builds on the core host (free_plan fallback)

```powershell
./scripts/aws-prod.ps1 images -Profile pulso-prod -Service core-runtime -SourceDir D:\src\improvement-engine -AgentCoreDir D:\src\agent-core -Builder host
```

`-Builder host` (default `codebuild`) uploads the zip as before, finds the running instance tagged `Workload=core`, and runs docker buildx there through SSM Run Command (`AWS-RunShellScript`, script written to the work directory, one command). It prints the tail of the output, reads the build record from `engine/build-out/` and records the digest exactly like the CodeBuild path. The build shares CPU and memory with the stack on that host: build while traffic is idle. Requires `enable_host_builder` (default true in free_plan).

## Postgres container (free_plan)

- State: `docker ps` on the core host (via SSM) shows `pulso-postgres-1`; data lives on `/srv/pgdata` (separate EBS volume, daily DLM snapshot, 3 kept).
- First start of an empty volume runs `initdb/10_init.sh` (databases and roles from `hackathon_data/sql/`); then run the engine's `db/sql` migrations on database `pulso` and `sql/30_pulso_logins.sql` (`docker compose -p pulso exec -T postgres psql -U pulso_master -d pulso < /srv/stack/initdb/sql/30_pulso_logins.sql`), as in [db-bootstrap](db-bootstrap.md) but without RDS.
- Restore: create a volume from a snapshot, swap it in `module.compute_core` (see Teardown notes) or restore into a new volume and `rsync` to `/srv/pgdata` with the stack stopped.
- DSNs in the secret point at `core.pulso.internal:5432` (`terraform output db_endpoint`).
