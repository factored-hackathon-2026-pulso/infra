# Hackathon deploy: order of operations (human)

Profile: THREE EC2 hosts (core, platform, engine; t3.small each, Amazon Linux 2023, private subnets, no public IP, no SSH), each running its own docker compose
bundle (`deploy/hackathon/<workload>/`). They find each other by private DNS in the Route 53 private zone: `core.<zone>`, `platform.<zone>`, `engine.<zone>`. One NAT gateway for egress. CloudFront with a VPC origin and WAF is the only public edge and sends HTTP to
the platform proxy on port 80 and the engine proxy on port 8080. Nothing here is applied by agents; every apply needs your explicit authorization.

## 0. Preconditions
- Bootstrap lane done: account prepared, state bucket and lock, billing budget/alerts.
- The real modules (`hackathon_network`, `hackathon_iam`, `hackathon_edge`, `hackathon_data`) are wired in `terraform/envs/hackathon/main.tf`; see `docs/hackathon-foundations.md` for the whole picture.
- Each host role (`instance_profile_name_core|platform|engine`) needs exactly: read the single `secret_arn` and `kms:Decrypt` on `kms_key_arn`; `ssm:GetParametersByPath`
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
Run once from the host via SSM Session Manager (the DB is reachable only from `sg_core_id, sg_platform_id, sg_engine_id`): use the master secret
named by `db_master_secret_ssm_name` to create the `pulso` database, run `db/sql/001_roles_schemas.sql` of the engine,
and create the Core database and logins. Store the resulting DSNs in the one secret, never in SQL or Git.

## 3. Set values out of band
- The ONE Secrets Manager secret (JSON). Keys are `<SERVICE>__<VAR>` with SERVICE in `COMMON, CORE, GATEWAY, SUPPORT, PULSO`
  (for example `GATEWAY__OPENAI_API_KEY`, `CORE__AGENTCORE_REGISTRY_DSN`, `SUPPORT__CC_SESSION_SECRET`); the exact list is in
  `docs/secrets-keys.md`. Edit with `aws secretsmanager put-secret-value`; values never go in Terraform, user_data or state.
- SSM parameters under `ssm_prefix` hold NON-secret config only, path `<ssm_prefix>/<workload>/<svc>/<VAR>` (for example `/pulso/core/gateway/LLM_ENDPOINTS`).

## 4. Push images
Build and push `agent-core` (pin c814c2b), `llm-gateway`, `support-api`, `support-web`, `pulso` (docker/pulso.Dockerfile) and a
mirror of the Caddy image to ECR (linux/amd64). Record each digest (`repo@sha256:...`) in your tfvars `images`.
No tags are used.

## 5. First start (three SSM sessions)
Each instance starts the `pulso-stack` systemd unit at boot: installs docker, mounts its data volume at `/srv`, syncs
`engine/deploy/<workload>/` from S3, logs in to ECR, renders `/run/pulso/env/*.env` (tmpfs, 0600) from ITS slice of the one secret
(core: COMMON, CORE, GATEWAY; platform: COMMON, SUPPORT; engine: COMMON, PULSO) and SSM, then runs `docker compose up -d`.
Start order matters once: bring up **core** first (`aws ssm start-session --target <core id>`; `docker compose -p pulso ps`, core-runtime healthy),
then **platform** and **engine**, which reach Core at `http://core.<zone>:8000`. Inside the core host the runtime reaches the gateway at
`http://llm-gateway:8080`. Open one SSM session per host and check `systemctl status pulso-stack`. A new digest: re-apply, then
`sudo systemctl restart pulso-stack` on that host. Per-host bootstrap: the DB bootstrap (step 2) runs from the core or engine session; the SQLite
for support-platform lives on the platform host volume `/srv/data/support`.
Core `:8000` is published on the core host and limited by `sg_core_id` to the platform and engine security groups; the gateway is never published.

## 6. Loading Parquet into the data lake
1. Upload Parquet files to `s3://<bucket>/landing/<dataset>/` from your machine with the uploader principal (PUT only).
2. The engine host role cannot read `landing/` or `lake/bronze/` (the bucket policy denies everyone but the loader role and
   break-glass principals, and the host role is not granted them). Run the loader (data pipeline task) under a role listed in
   `loader_role_arns`, reading through the VPC S3 endpoint; it writes `lake/`. The engine host reads only
   `lake/gold_masked/` and `lake/gold_analytics/`.
3. Engine outputs under `engine/` follow the prefix contract in `terraform/modules/hackathon_data/README.md`.