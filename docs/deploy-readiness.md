# Deploy readiness (WS7): what must be true before the first apply

Everything in this page is OFFLINE preparation. Nothing here applies, plans against AWS, calls a model or reads a secret value. The human runs every command that touches AWS, in this order, and types the confirmation words the scripts ask for. Status of the work as of this branch: the infra side is wired and tested with mocked providers and static contract tests; the support-platform items still open (below) and the human-provided secrets are what remains for a first end-to-end bring-up.

Related: [aws-prod-quickstart](aws-prod-quickstart.md) (the commands), [aws-plan-review-checklist](aws-plan-review-checklist.md) (the grep checks), [operations](operations.md), [costs](costs.md), [agent-core-serve](agent-core-serve.md), [engine-loop](engine-loop.md), [otlp-forwarder](otlp-forwarder.md), [run-and-health](run-and-health.md).

## Offline plan review

Without credentials, in this order, from the repository root. One Terraform command at a time; the provider plugin must already be cached (or `terraform init -backend=false` has run once per root).

1. `python -m unittest discover -s tests` (static contracts: bundles, secret key lists, ordering, never-doubles, docs consistency).
2. `terraform fmt -check -recursive terraform`
3. `python scripts/aws_plan_review.py --validate` (account-agnostic grep rules, [checklist](aws-plan-review-checklist.md)).
4. Mocked-provider tests, one directory at a time: `terraform -chdir=terraform/modules/hackathon_data test`, then `hackathon_compute`, then `terraform/envs/hackathon`, then `terraform/bootstrap`.
5. With credentials (human): `.\scripts\aws-prod.ps1 plan -Profile pulso-prod` writes a saved plan and prints a summary. Review it OFFLINE from the saved plan: `terraform -chdir=terraform/envs/hackathon show -json <planfile>` and check each of these (a reviewer who cannot run AWS can do this from the JSON):
   - zero `delete` and zero `replace` actions on: the data and Postgres volumes (`aws_ebs_volume`), the secret and its version, the KMS key, the data bucket, the state bucket, the Route 53 zone. All of them carry `prevent_destroy` or `ignore_changes` except the secret version, which must show NO change (it ignores `secret_string`).
   - the three `aws_instance` resources: on a FIRST apply they are creates. On any later apply a change of a start script (`user_data`, which the loop, sweep, forwarder and in-place key rewrite all change) shows `replace` on the instance (`user_data_replace_on_change`); data volumes persist and re-attach. Plan the replacement window; the engine `PULSO_CORE_ADDR` and `PULSO_LLM_GATEWAY_ADDR` SSM values are rewritten with the new private IP.
   - SSM image parameters show `create` only (their value is `ignore_changes`): no digest changes by apply.
   - `aws_ssm_parameter.derived["engine/pulso/PULSO_SERVICE_KID"]` equals `pulso-engine-<suffix>` of the active engine key.
   - secrets: the plan contains `(sensitive value)` for key material and no secret value in clear; `grep -i "BEGIN PRIVATE KEY"` of the plan JSON finds nothing (the state does hold the generated keys: the state bucket is the protection).
   - no security group with `0.0.0.0/0` ingress; 8001 and 8080 on the core host only from sibling groups; no port for the forwarder (it is loopback).
   - IAM: no `Action "*"`; the engine role has no `landing/` or `lake/bronze` read (`engine_host_can_load = false`).
6. Record the plan's sha256 and the counts (add, change, destroy) in the journal; the apply uses that saved plan.

## State key migration (documented only; the user executes)

The hackathon root's backend key is `pulso/prod/hackathon/terraform.tfstate` (`terraform/envs/hackathon/backend.hcl.example`, `scripts/aws-prod.ps1`). The older `terraform/envs/prod` root used `pulso/prod/terraform.tfstate`. Whether any state exists at the old key is not known from the repository [U], and nothing may be deleted: the migration COPIES.

1. Stop: confirm no Terraform run anywhere and no `.tflock` next to either key (`aws s3 ls s3://pulso-prod-tfstate-<account id>/pulso/prod/ --profile pulso-prod`).
2. Look: `aws s3api head-object --bucket pulso-prod-tfstate-<account id> --key pulso/prod/terraform.tfstate --profile pulso-prod`.
   - 404 (expected on a fresh account): nothing to migrate; `aws-prod.ps1 plan` initializes the new key. Stop here.
   - exists: back it up first: `aws s3 cp s3://pulso-prod-tfstate-<account id>/pulso/prod/terraform.tfstate .scratch/state-backup/prod.tfstate --profile pulso-prod` (outside Git; the state holds secrets).
3. Classify: initialize the OLD key in a throwaway copy of the root that wrote it and run `terraform state list`. If it lists `module.compute_core`, `module.data`, `module.network` (the hackathon root), migrate it. If it lists bridge-services, engine-task or data-lake resources (the `terraform/envs/prod` root), it belongs to THAT root: do not move it into the hackathon root.
4. Migrate (hackathon resources only): in `terraform/envs/hackathon`, `terraform init -reconfigure -backend-config=<file with the OLD key>`, then `terraform init -migrate-state -backend-config=<file with key = "pulso/prod/hackathon/terraform.tfstate">` and answer `yes` to copy. Verify: `terraform state list | Measure-Object` equals the count from step 3, and a plan with credentials shows no changes beyond what step 5 of plan review expects.
5. Keep the old object until a clean plan on the new key has been reviewed; delete it only by an explicit decision (the bucket is versioned [U: confirm in the bootstrap module]). Rollback: point the backend back at the old key; the copy is untouched.

## Secrets checklist

One Secrets Manager secret `pulso-prod/hackathon`. Terraform generates or derives EVERY value except the external provider keys ([secrets-wiring](secrets-wiring.md) has the per-variable inventory); it ignores later changes. Names only; never paste a value into chat, a file in Git or a command line. On an existing secret add the wired keys with `aws-prod.ps1 seed-secret-keys` (merge only). Check set/unset names with `aws-prod.ps1 status`.

| Name | Who provides | When needed |
|---|---|---|
| `GATEWAY__OPENROUTER_API_KEY` | human, from OpenRouter | every model call |
| `GATEWAY__JEV_API_KEY` (also written to `AGENT__AGENTCORE_JEV_API_KEY` by `set-secret`) | human, from the JEV provider | agent-core serve does not start without it |
| `LANGFUSE__LANGFUSE_PUBLIC_KEY`, `LANGFUSE__LANGFUSE_SECRET_KEY` | human, optional, from the Langfuse project | `otlp_forwarder_enabled` |
| Database passwords (`DB__DB_PASSWORD_*`, `DB__POSTGRES_PASSWORD`) and every DSN (`AGENT__AGENTCORE_*_DSN`, `CORE__AGENTCORE_*_DSN`, `SUPPORT__CC_DATABASE_URL`, `MIGRATE__CC_DATABASE_URL`, `PULSO__PULSO_DATABASE_URL`, `PULSO__PULSO_PG_PRODUCT_DSN`) | Terraform: passwords generated, DSNs assembled from them and the private zone name | database container, every service |
| `SUPPORT__CC_SESSION_SECRET`, `SUPPORT__CC_TOTP_SECRET_KEY`, `LOADER__PSEUDONYM_KEY` | Terraform generates (rotating the pseudonym key changes every pseudonym) | platform, `auto_loader_enabled` |
| `FILES__AGENT__FIELD_GRANTS`, `FILES__AGENT__FIELD_OVERLAY`, `FILES__AGENT__FX_RATES`, `FILES__SUPPORT__BANK_CUSTOMER_LINKS` | authored files in `deploy/hackathon/config/` with least-privilege defaults, FLAGGED for review by the agent-core and data teams | agent services, platform |
| Gateway tokens, tool-service token, `AGENT__AGENTCORE_KEYS_FINGERPRINT`, `AGENT__AGENTCORE_KEYS_TOKEN_MAP`, `AGENT__AGENTCORE_GRANTS_TOKEN` and `SUPPORT__CC_INTERNAL_SERVICE_TOKEN` (one value), `PULSO__PULSO_SERVICE_SEED_HEX`, `PULSO__PULSO_ADMIN_TOKEN`, `PULSO__PULSO_DEBUG_TOKEN`, `PULSO__PULSO_PLATFORM_SERVICE_TOKEN`, the key documents | Terraform | always |

Never present anywhere: `AGENTCORE_ALLOW_DOUBLES`, `PULSO_REGISTRY_TOKEN`. Full key list: [secrets-keys](secrets-keys.md).

## Apply order

Each step is a separate human decision; stop and review between steps. The first apply is a saved plan of the whole stack unless the account is brand new (builder stage).

1. `aws-prod.ps1 bootstrap-plan`, review, `bootstrap-apply`: state bucket and the ECR repositories (nine plus `otlp-forwarder`). Skip if applied; the plan must show only the new repository.
2. Brand-new account only: `plan -Stage builder`, `apply` (network, data, CodeBuild builder, no hosts).
3. Build and push images, one at a time (`aws-prod.ps1 images`): `llm-gateway`, `tool-service`, `agent-core-serve` (agent-core's own Dockerfile), `caddy` mirror, `pulso-engine` (the ENGPROD image), `support-platform-api`, `support-platform-web`; optional `data-pipeline` and `otlp-forwarder`. Digests land in `prod.tfvars` (uncommitted).
4. Set the flags in `prod.tfvars` (suggested first bring-up: `agent_services_enabled = true`, `platform_database_enabled = true`; the loop, loader and forwarder only after their prerequisites below).
5. `plan` and the offline review above, then `apply`.
6. Secrets: set the provider keys ([human-secrets-only](human-secrets-only.md)); `seed-secret-keys` if the secret pre-existed; check names only with `status`.
7. Database: first start of the core host runs the initdb; Postgres role passwords must exist before it. Start core first: `pulso-stack`, `docker compose -p pulso ps` until `postgres`, `llm-gateway`, `tool-service` and `agent-core` are healthy (`agent-core-migrate` exited 0).
8. Platform host, then engine host. After the engine's first start run `pulso-db-bootstrap` (a core redeploy) and switch the engine DSN to `pulso_app`.
9. Data: upload `landing/`, write the loader marker ([auto-loader](auto-loader.md)); cells land in `lake/gold_analytics/bank_cells/`.
10. Loop: `engine_loop_enabled = true`, plan, apply; `systemctl start pulso-loop` once and read `journalctl -u pulso-loop`.
11. Smoke: `aws-prod.ps1 status`; `GET /readyz` on agent-core from the platform host; one registry call as the engine (the first loop run).

## Cost estimate (chosen profile)

Profile: `free_plan` with `agent_services_enabled`, `platform_database_enabled`, `auto_loader_enabled`, `engine_loop_enabled`, forwarder off. us-east-1 on-demand, 730 h per month (hosts always on), no Free Plan credits modelled. Prices are from memory of the public pricing pages and UNVERIFIED: check the AWS pricing pages and the Billing console before relying on them.

| Item | Assumption | USD per month |
|---|---|---|
| core `m7i-flex.large` | 0.0958 per hour | 70 |
| engine `m7i-flex.large` (loader on; `t3.small` without it saves ~49) | 0.0958 per hour | 70 |
| platform `t3.small` | 0.0208 per hour | 15 |
| public IPv4 x3 | 0.005 per hour each | 11 |
| EBS gp3 | 3 x 20 GB root + 20 + 20 + 40 GB data + 30 GB Postgres = 170 GB at 0.08 | 14 |
| EBS snapshots (daily, 3 kept) | about 100 GB stored at 0.05 | 5 |
| KMS key, Secrets Manager, Route 53 private zone | 1 + 0.40 + 0.50 | 2 |
| S3 (curated lake and engine outputs, no raw `landing/` kept) | about 50 GB | 1 |
| ECR (10 repositories), CodeBuild small | about 2 GB, about 30 builds of 10 minutes | 2 |
| CloudFront, SSM, WAF off, NAT none, CloudWatch off | free tier or disabled | 0 |
| **Total infrastructure** | | **about 190** |

Not included: model usage (OpenRouter, JEV), Langfuse Cloud plan, `t3` CPU-credit surcharge if a host runs above baseline, data transfer above the free allowance, taxes. Levers: `enabled = { ..., engine = false }` stops a host (volumes keep billing), engine back to `t3.small` without the loader (about 135 total), `edge_enabled = false`. Treat the number as a planning figure until the first Cost Explorer week.

## Rollback

- Before the first apply: nothing exists; discard the plan.
- A bad image: `aws-prod.ps1 deploy -Rollback` (the host script restores the previous digests and brings the stack up on them; `DEPLOY_RESULT=rolled_back`).
- A bad apply: re-apply the previous saved plan's configuration (a revert commit and a new plan); instance replacement keeps the data volumes. For a bad start script use the previous `user_data` by reverting and re-planning; expect another replacement.
- The loop, forwarder and sweep: set their variable to `false` and apply (the units stay installed until the host is replaced; `systemctl disable --now pulso-loop.timer` immediately).
- Engine key rotation: [agent-core-serve](agent-core-serve.md#7-rotation-of-the-engine-key-a5) lists the revert per step.
- Teardown: [operations](operations.md#teardown); data protections block it on purpose.

## Blockers owned by the support-platform team

Re-checked against support-platform `main` (PRs 27 to 40) on 2026-10-06; evidence with file and line in `docs/reports-claude/PLATFORM_DEPLOY_READINESS_2026-10-06.md`. Contract: `docs/platform/deploy-env.md` of that repository.

1. **Postgres and migrations: delivered (PR 33).** psycopg 3 (`postgresql://` is enough; `postgresql+asyncpg://` does NOT work), Alembic, `cc-migrate` reading only `CC_DATABASE_URL` (so the owner DSN is passed under that name to a one-shot job; there is no `CC_MIGRATE_DATABASE_URL`), advisory lock, exporter column grants. Infra side: `MIGRATE__CC_DATABASE_URL` -> `migrate.env` -> service `support-platform-migrate`; the API runs with `CC_MIGRATE_ON_START=false`; `26_platform_exporter_grants.sql` is column level. `platform_database_enabled` may now be switched on.
2. **Images: partly delivered.** Builds from a clean checkout (python 3.12-slim, node 22 + nginx). Still open on the platform side: no `USER` (root; compose sets `user: 10001:10001`), no `HEALTHCHECK` (compose uses `/readyz`), `VITE_API_URL` default is localhost (pass the CloudFront URL at build). amd64 is not exercised (nothing was built).
3. **Environment contract: delivered (PR 39).** `docs/platform/deploy-env.md`; the platform host sets `CC_ENV=staging`, `CC_TRUSTED_PROXIES`, `CC_MIGRATE_ON_START`, `CC_AGENT_CORE_TIMEOUT_SECONDS=55` and the rest as listed in `deploy/hackathon/platform/compose*.yaml`.
4. **Announce, evidence and grant endpoints: delivered (PRs 27, 32, 37, 39).** Shared bearer `CC_INTERNAL_SERVICE_TOKEN` (404 while unset, 401 on a wrong bearer); WebSocket heartbeat 25 s. A per-consumer token is still an ask.

Not support-platform's, but also blocking a full loop: the ENGPROD engine image with python3 and the regression scripts (engine team), agent-core `eval_suite` fixtures and the blob backfill decision (agent-core team), the loader contract confirmations in `ASK_data-pipeline_loader_2026-10-05` (data-pipeline team), and the external provider keys above.

## What is not verified

No `terraform plan` or `apply` ran against AWS; no image was built; no systemd unit, compose file or `serve` instance was started. The mocked-provider tests check structure, not behaviour of AWS. The cost figures are estimates from remembered prices. Whether anything exists at the old state key is unknown.
