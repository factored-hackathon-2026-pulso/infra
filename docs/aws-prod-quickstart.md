# AWS prod quickstart (one page)

One environment (`prod`), region us-east-1, one new AWS account, everything driven by `scripts/aws-prod.ps1` from your machine. No budgets, no CI role, no Organizations or Identity Center. Nothing is applied without a saved plan, a printed summary and you typing `APPLY`. Longer docs: [operations](operations.md), [architecture](architecture.md), [security model](security-model.md), [costs](costs.md), [troubleshooting](troubleshooting.md).

Prerequisites on your machine: PowerShell 7, Terraform >= 1.10, AWS CLI v2, Docker, Git, and these repos cloned next to each other (paths are examples): the Pulso engine, `agent-core`, `llm-gateway`, `support-platform`.

1. **Create access (root user: the chosen path for now).** Sign in to the new account's console as root, then: (a) enable MFA on root (account menu > Security credentials > Multi-factor authentication); (b) Security credentials > Access keys > Create access key, and keep the page open; (c) in PowerShell enter it ONLY here, never in chat, files or scripts: `aws configure --profile pulso-prod` (region `us-east-1`, output `json`). Root is account-wide and no permission boundary applies to it, so delete the key when the deployment is done (step 12). Safer later alternative: an IAM user `pulso-admin` with `AdministratorAccess` and one access key, entered the same way, with MFA on the user ([security-model](security-model.md)).

2. **Check who you are** (prints account id and ARN type, warns once if you are root, never blocks):
   ```powershell
   .\scripts\aws-prod.ps1 check -Profile pulso-prod
   ```
   Compare the account id with the console by eye. Profile names `default`, `payana*`, `higo*`, `standar*`, `management*` are refused unless `-AllowAnyProfile`.

3. **Bootstrap** (skip if already applied: the defaults match the applied one, a plan shows no changes; state bucket `pulso-prod-tfstate-<account id>` and the ECR repositories; no inputs needed):
   ```powershell
   .\scripts\aws-prod.ps1 bootstrap-plan -Profile pulso-prod
   .\scripts\aws-prod.ps1 bootstrap-apply -Profile pulso-prod     # read the summary, type APPLY
   ```

4. **Build and push the images** (writes digests into the uncommitted `terraform/envs/hackathon/prod.tfvars`; copy of [prod.tfvars.example](../terraform/envs/hackathon/prod.tfvars.example)). `-CaddyUpstreamDigest` is the upstream caddy image digest you choose to mirror:
   ```powershell
   .\scripts\aws-prod.ps1 images -Profile pulso-prod -PulsoDir D:\src\improvement-engine -AgentCoreDir D:\src\agent-core -LlmGatewayDir D:\src\llm-gateway -SupportPlatformDir D:\src\support-platform -CaddyUpstreamDigest sha256:<64 hex>
   ```

   No local Docker (the Podman machine is too small)? Build in AWS instead: `.\scripts\aws-prod.ps1 plan -Profile pulso-prod -Stage builder`, `apply`, then one `.\scripts\aws-prod.ps1 images -Profile pulso-prod -Service <name> -SourceDir <dir>` per service (agent-core also takes `-AgentCoreDir`, caddy takes `-MirrorImage`); details in [service-deployment](service-deployment.md#c-first-bring-up-of-an-empty-account-infra-owner-only).

5. **Plan and apply the stack** (VPC, NAT, RDS, bucket, KMS, secret, 3 hosts, CloudFront + WAF):
   ```powershell
   .\scripts\aws-prod.ps1 plan -Profile pulso-prod
   .\scripts\aws-prod.ps1 apply -Profile pulso-prod                # type APPLY
   ```

6. **Secrets.** Terraform seeds placeholders in the one secret `pulso-prod/hackathon`; set each provider key with `.\scripts\aws-prod.ps1 set-secret -Profile pulso-prod -SecretKey GATEWAY__OPENROUTER_API_KEY` (secure prompt, no echo, nothing printed or logged; see [secrets-keys](secrets-keys.md)), or set real values (keys in [secrets-keys](secrets-keys.md)) from the console (Secrets Manager > Retrieve > Edit) or `aws secretsmanager put-secret-value --profile pulso-prod --secret-id pulso-prod/hackathon --secret-string file://secret.json` with a temporary file you delete right after. Never paste values anywhere else. On a secret that already exists, add the Terraform-generated keys (gateway tokens, Ed25519 keys) without touching the rest with `.\scripts\aws-prod.ps1 seed-secret-keys -Profile pulso-prod` (merge only; never `terraform apply -replace` the secret version).

7. **Database bootstrap** from a host shell (`aws ssm start-session --profile pulso-prod --target <engine instance id>`, ids from `.\scripts\aws-prod.ps1 status -Profile pulso-prod`). Needs `psql` 15 or newer on the host (`sudo dnf install -y postgresql15`). Follow [db-bootstrap](db-bootstrap.md), then write the four DSNs into the secret.

8. **First start order.** Core first, then platform and engine. On each host: `sudo systemctl restart pulso-stack`, then `docker compose -p pulso ps` until healthy. Details: [operations](operations.md).

9. **Upload your data** (goes to `landing/<dataset>/`, SSE-KMS; agent can guide you through the loader):
   ```powershell
   .\scripts\aws-prod.ps1 upload -Profile pulso-prod -Path D:\data\e0 -Dataset e0 -DryRun
   .\scripts\aws-prod.ps1 upload -Profile pulso-prod -Path D:\data\e0 -Dataset e0
   ```
   Then upload `landing/` and write `engine/inbox/READY.json`: the automatic loader (`auto_loader_enabled`) does landing -> lake. See [auto-loader](auto-loader.md).

10. **Smoke tests.** `.\scripts\aws-prod.ps1 status -Profile pulso-prod` (instances running, `pulso-stack` active, containers up). Then open `https://<cloudfront domain>/` (platform) and the engine routes under `/pulso/`; the domain is `terraform -chdir=terraform/envs/hackathon output cloudfront_domain_name`.

11. **Stop or save money.** Stop a host with `enabled = { core = true, platform = true, engine = false }` in `prod.tfvars`, then `plan` and `apply`. WAF off: `enable_waf = false`. See [costs](costs.md).

12. **Clean up root access.** Console > Security credentials > Access keys > Deactivate, then Delete the root key (and run `aws configure --profile pulso-prod` again only if you create a new key). Run `.\scripts\aws-prod.ps1 root-keys-reminder` to see the three safety lines again.

**Teardown:** `.\scripts\aws-prod.ps1 destroy-plan -Profile pulso-prod`, then `.\scripts\aws-prod.ps1 destroy -Profile pulso-prod` (type `DESTROY`). Data-volume and RDS protections block it on purpose; the order is in [operations](operations.md#teardown).
