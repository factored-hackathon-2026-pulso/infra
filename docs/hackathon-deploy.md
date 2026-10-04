# Hackathon deploy: order of operations (human)

Profile: ONE EC2 (t3.large, Amazon Linux 2023, private subnet, no public IP, no SSH) running a docker compose
stack. One NAT gateway for egress. CloudFront with a VPC origin and WAF is the only public edge and sends HTTP to
the proxy on port 80. Nothing here is applied by agents; every apply needs your explicit authorization.

## 0. Preconditions
- Bootstrap lane done: account prepared, state bucket and lock, billing budget/alerts.
- Lane A modules (`hackathon_network`, `hackathon_iam`, `hackathon_edge`) and lane B (`hackathon_data`) merged in
  place of the stubs. Reconcile their real inputs with `terraform/envs/hackathon/main.tf` (the stubs fix only the outputs).
- The host role needs exactly: read the single `secret_arn` and `kms:Decrypt` on `kms_key_arn`; `ssm:GetParametersByPath`
  on `ssm_parameter_arn_prefix`; S3 read on `engine/deploy/*` and read/write on the engine/core/landing prefixes of the
  bucket; ECR pull; SSM Session Manager core (`AmazonSSMManagedInstanceCore`); optional CloudWatch Logs.
- `engine/deploy/` in the bucket must not be covered by an expiry lifecycle rule (compose bundle lives there).

## 1. Apply order
1. `hackathon_network` (VPC, subnets, NAT, endpoints, security groups).
2. `hackathon_data` (RDS, bucket with prefixes `landing/`, `lake/bronze|silver|gold`, `engine/artifacts|evidence|reports|console`,
   `core/blobs`, `logs/`, `tmp/`; the one secret, KMS key, SSM prefix).
3. `hackathon_iam`.
4. Compute needs images in ECR first (step 4 below), because `images` takes digests.
5. `hackathon_compute` then `hackathon_edge` (edge needs the instance id and private IP).
In practice run one `terraform apply` of `envs/hackathon` after steps 2 to 4 are ready; use `-target` only if a
module order problem forces it.

## 2. Database bootstrap
Run once from the host via SSM Session Manager (the DB is reachable only from `sg_host_id`): use the master secret
named by `db_master_secret_ssm_name` to create the `pulso` database, run `db/sql/001_roles_schemas.sql` of the engine,
and create the Core database and logins. Store the resulting DSNs in the one secret, never in SQL or Git.

## 3. Set values out of band
- The ONE Secrets Manager secret (JSON). Keys are `<SERVICE>__<VAR>` with SERVICE in `COMMON, CORE, GATEWAY, SUPPORT, PULSO`
  (for example `GATEWAY__PROVIDER_KEY`, `CORE__DATABASE_URL`, `SUPPORT__SECRET_KEY`); lane B documents the exact list in
  `docs/secrets-keys.md`. Edit with `aws secretsmanager put-secret-value`; values never go in Terraform, user_data or state.
- SSM parameters under `ssm_prefix` hold NON-secret config only, path `<ssm_prefix>/<svc>/<VAR>`.

## 4. Push images
Build and push `agent-core` (pin c814c2b), `llm-gateway`, `support-api`, `support-web`, `pulso` (docker/pulso.Dockerfile) and a
mirror of the Caddy image to ECR (linux/amd64). Record each digest (`repo@sha256:...`) in your tfvars `images`.
No tags are used.

## 5. First start
The instance starts the `pulso-stack` systemd unit at boot: it installs docker, mounts the data volume at `/srv`, syncs the
bundle from S3, logs in to ECR, renders `/run/pulso/env/*.env` (tmpfs, 0600) from the secret and SSM, then runs
`docker compose up -d`. Connect with `aws ssm start-session --target <instance_id>`; check `systemctl status pulso-stack`
and `docker compose -p pulso ps`. A new image digest: re-apply, then `sudo systemctl restart pulso-stack`.

## 6. Loading Parquet into the engine
1. Upload Parquet files to `s3://<bucket>/landing/<dataset>/` from your machine.
2. Open an SSM session on the host and run the loader inside the engine image (reads Parquet, writes the product tables):
   `docker compose -p pulso run --rm pulso python db/loader/load_parquet.py --source s3://<bucket>/landing/<dataset>/`
   (adjust the command to the final `pulso` image entrypoint; the loader path is `db/loader/load_parquet.py` in the engine repo).
   Alternatively `aws ssm send-command` with the same command line against the instance.
3. Bronze/silver/gold under `lake/` and engine outputs under `engine/` follow lane B's prefix contract.

## 7. Smoke tests (through the CloudFront domain)
`GET /healthz` returns ok (proxy); `/` serves the support web app; `/api/...` reaches support-platform and `/api/v1/ws` upgrades;
`/pulso/` opens the console; `/internal`, `/api/internal`, `/pulso/internal` return 404. On the host: Core `/readyz` and gateway `/healthz`.

## 8. Cost control and teardown
- Pause: `terraform apply -var enabled=false` stops the instance (EBS, NAT, RDS, CloudFront keep costing; stop RDS in lane B if supported).
- Emergency: `sudo systemctl stop pulso-stack`.
- Teardown: set `protect_data_volume=false` and apply (this swaps the data volume resource: snapshot first), then `terraform destroy`.
  The bucket and snapshots follow lane B's retention rules.

Monthly estimate (us-east-1, 24x7): t3.large about 61 USD, EBS 60 GB gp3 about 5 USD plus snapshots about 1 USD, one NAT gateway about 33 USD plus
data, public IPv4 on NAT/edge about 4 USD; compute-lane subtotal about 105 USD. RDS, S3, CloudFront and WAF (lane A/B) add on top.
Using `enabled=false` outside demo hours cuts the instance share.
