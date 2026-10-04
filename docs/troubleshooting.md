# Troubleshooting

Known failure modes, with the exact checks. Host commands run in an SSM shell: `aws ssm start-session --profile pulso-prod --region us-east-1 --target <instance id>`.

## Provider start timeout

Symptom: `terraform init`, `validate` or `test` hangs or fails with "timeout while waiting for plugin to start" (large aws provider on Windows, antivirus scanning).
Checks: only one terraform process runs (`Get-Process terraform`); `$env:TF_PLUGIN_CACHE_DIR = 'D:/tf-plugin-cache'` is set; the provider is already cached. Kill a run that exceeds about 6 minutes and retry once. Add the plugin cache directory to the antivirus exclusions if it keeps happening.

## CloudFront VPC origin

CloudFront VPC origins pointing straight at a private EC2 instance are accepted only at first apply (the offline tests cannot prove it).
Symptoms: `apply` fails on `aws_cloudfront_vpc_origin`, or the site returns 502/504.
Checks: the host security groups admit the CloudFront origin-facing prefix list on 80 (platform) and 8080 (engine); the proxy answers locally (`curl -s -o /dev/null -w "%{http_code}" http://localhost:80/healthz` on platform, `:8080` on engine); the instance is `running` (`.\scripts\aws-prod.ps1 status -Profile pulso-prod`).
Fallback if the API rejects an instance ARN as a VPC origin: add an internal Application Load Balancer in the private subnets targeting the host, pass its ARN as `platform_origin_arn` / `engine_origin_arn` in `terraform/envs/hackathon/main.tf` (the edge module accepts an ALB or NLB ARN), and allow the ALB security group on the host ports. This is a code change: write the module test first ([modification-guide](modification-guide.md)).

## Host does not come up

1. Instance state: `.\scripts\aws-prod.ps1 status -Profile pulso-prod`. Not listed or `stopped`: check `enabled` in `prod.tfvars`.
2. No SSM session: the instance needs outbound 443 through the NAT (check the NAT gateway and private route table), the profile `AmazonSSMManagedInstanceCore` attached, and a few minutes after boot. Console > Systems Manager > Fleet Manager shows whether it registered.
3. Boot log: `sudo tail -n 200 /var/log/cloud-init-output.log`, then `sudo journalctl -u pulso-stack -b --no-pager`.
4. `user_data` failures: docker or compose download blocked (no egress), or the data volume not attached yet (`lsblk`; `/srv` mounted?).
5. ECR login: `aws ecr get-login-password --region us-east-1 | docker login ...` inside the unit fails with AccessDenied when the image repository is not in `images` (pull rights are derived from `images`) or the registry URL is wrong. Check the image refs are `<registry>/<repo>@sha256:...` and the repository exists (bootstrap).
6. Secret read: `aws secretsmanager get-secret-value --secret-id pulso-prod/hackathon --region us-east-1 --query Name` from the host. AccessDenied means the instance profile is wrong; `ResourceNotFound` that the secret is scheduled for deletion or the name prefix changed.
7. Missing bundle: `aws s3 ls s3://<bucket>/engine/deploy/<workload>/` must list `compose.yaml`; it is created by `apply`.

## Containers unhealthy

`docker compose -p pulso ps` then `docker compose -p pulso logs --tail 100 <service>`. Usual causes: a secret key still `CHANGE_ME` (rendered env is in `/run/pulso/env/<service>.env`, check names only, do not paste values), the DSN keys not written after the DB bootstrap, a wrong image digest (`docker compose -p pulso config | grep image`), out of memory on t3.small (`docker stats --no-stream`; raise `instance_types`).

## Database unreachable from a host

Checks on the host: DNS (`getent hosts <db endpoint>`); port (`timeout 3 bash -c '</dev/tcp/<endpoint>/5432' && echo open`); security group `sg_db` admits the host's group; TLS is forced (`sslmode=require` in the DSN); role and password match [db-bootstrap](db-bootstrap.md). `psql` older than 15 cannot run the bootstrap scripts (`\getenv`).

## Start order: core first

Platform and engine call core on `core.pulso.internal:8000`. If they restart-loop right after a first deploy, check core: `curl -s -o /dev/null -w "%{http_code}" http://localhost:8000/` on the core host, and that `core-migrate` completed (`docker compose -p pulso ps -a`). Then `sudo systemctl restart pulso-stack` on platform and engine.

## WAF false positives

Symptom: legitimate requests get 403 from CloudFront. Console > WAF & Shield > Web ACLs (scope CloudFront, region N. Virginia) > Sampled requests shows the rule that blocked. Short term: `enable_waf = false` in `prod.tfvars`, `plan`, `apply`. Longer term: switch the offending managed rule to count mode in `terraform/modules/hackathon_edge` (test first).

## State lock stuck

Symptom: "Error acquiring the state lock" after an interrupted run. First confirm no terraform is running anywhere (`Get-Process terraform`). Native S3 locking writes `<state key>.tflock` in the state bucket: `aws s3 rm s3://pulso-prod-tfstate-<account id>/pulso/prod/hackathon/terraform.tfstate.tflock --profile pulso-prod`, or `terraform -chdir=terraform/envs/hackathon force-unlock <lock id>` (the id is in the error). Never force-unlock while another apply may be running.

## The helper script refuses

`Refusing profile`: the profile name is one of the protected names; use `pulso-prod`. `No saved plan`: run the matching plan subcommand first. `Aborted`: the confirmation word must be typed exactly (`APPLY` or `DESTROY`, upper case). `placeholders`: `prod.tfvars` still has `REPLACE_WITH` or `<registry>`; run `images`.
