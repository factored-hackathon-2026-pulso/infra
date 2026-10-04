# Runbook: preparing a brand-new AWS account for Pulso

Audience: the human who owns the new, empty AWS account. Nothing here has been run against any account; the
Terraform in `terraform/bootstrap` is validated and tested offline only (mock provider). Never paste keys, secrets or
account ids into chat, issues or Git.

**Rule: `terraform apply` (bootstrap or anything else) spends money and changes the account. It requires your
explicit, per-apply go-ahead after you have read the saved plan. No agent, CI job or script applies on its own.**

## 0. Decisions you make first (see `docs/aws-asks.md`)

| Decision | Variable / place |
|---|---|
| Region (AWS-02) | `aws_region` (no default on purpose) |
| Globally unique state bucket name (AWS-05) | `state_bucket_name` |
| Mailbox you read, for budget alerts (AWS-07) | `budget_alert_email` |
| Monthly ceiling in USD (AWS-06) | `monthly_budget_usd` (default 100) |
| GitHub org and infra repo name (AWS-03) | `github_org`, `github_repo` (empty = no OIDC role yet) |
| Keep CloudTrail (cheap, recommended) | `cloudtrail_enabled` (default true) |

Put them in `terraform/bootstrap/terraform.tfvars`. It is ignored by Git (verify with `git status` before any commit).

## 1. Human-only account preparation (console, in this order)

1. Sign in as the account root user with the email you chose. Set a strong unique password in your password manager.
2. Enable MFA on root (hardware key or authenticator app). Add a second MFA device if the console offers it.
3. Billing: enable "IAM user and role access to Billing", turn on free-tier usage alerts and Cost Explorer.
4. Create a billing alert in the console as a safety net before Terraform exists (a 10-20 USD CloudWatch or Budgets alert).
5. Enable IAM Identity Center in the chosen region, create yourself a user, a permission set (for example
   `AdministratorAccess` for the bootstrap only; narrow it later) and assign it to the account. Prefer this over IAM
   users with long-lived keys. If you must use an IAM admin user, enable MFA and never create access keys for root.
6. On your machine run `aws configure sso --profile <new-profile>` yourself (choose a name that does not collide with
   your existing profiles) and `aws sso login --profile <new-profile>`. Do not share any token or `~/.aws` content.
7. Verify you are in the right account before anything else:
   `aws sts get-caller-identity --profile <new-profile>` and compare the account id by eye with the console.
   Check it is NOT one of your other accounts.

## 2. Bootstrap (local state first)

```powershell
cd terraform/bootstrap
$env:AWS_PROFILE = "<new-profile>"        # never default or another account's profile
terraform init
terraform plan -out bootstrap.tfplan      # read it fully
```

What the first plan shows (about 20-25 resources): the state bucket (versioned, AES256, public access blocked,
TLS-only policy), an account-level S3 public access block, an optional alias, the budget with 50/80/100 % alerts
(only if `budget_alert_email` is set), CloudTrail plus its private log bucket, the ECR repository
`<prefix>/pulso-engine` (immutable tags, scan on push, lifecycle) and, if org/repo are set, the GitHub OIDC provider
and the read-only plan/push role `pulso-infra-ci`. It must show 0 changes to anything else and 0 destroys. Run
`python scripts/aws_plan_review.py` first; it must exit 0.

Only after you have read the plan and decided to spend, run `terraform apply bootstrap.tfplan`. Confirm the budget
subscription email that AWS sends.

## 3. Move bootstrap state into its own bucket (optional, recommended)

```powershell
terraform output -raw backend_hcl   # shows the bucket, key and region to use
```

Add a `backend "s3" {}` block (for example in an uncommitted `backend_override.tf`), save the output as
`backend.hcl` outside Git (change the `key` to `bootstrap/terraform.tfstate`) and run
`terraform init -migrate-state -backend-config=backend.hcl`. Keep the local `terraform.tfstate` until the migration is
verified; it is ignored by Git and contains no secrets of value but must not be shared.

## 4. Point an environment at the new state bucket

Copy `terraform/envs/<env>/backend.hcl.example` to a file OUTSIDE the repository, then replace
`bucket` with the output of step 3 and keep `use_lockfile = true` and `encrypt = true`:

```powershell
terraform -chdir=terraform/envs/staging init -backend-config=C:\path\outside\git\backend-staging.hcl
terraform -chdir=terraform/envs/staging plan -var-file=C:\path\outside\git\staging.tfvars -out staging.tfplan
```

The first plan of an environment creates a lot (VPC, NAT or endpoints, RDS, ECS...) and several of those cost money
per hour. Review costs line by line, keep every `*_enabled` switch false until you decide, and record the saved plan
sha. Applies happen from your machine with your SSO profile, never from CI (the CI role is read-only plus state/ECR).

## 5. Publish the first image

```powershell
./scripts/release-engine.ps1 -Context <engine repo> -Push -AwsProfile <new-profile> `
    -EcrRepository <value of terraform output ecr_repository_urls>
```

Without `-Push` it only builds locally. With `-Push` it refuses unless a non-default profile and a repository are
given, and records the registry digest in `release-out/deploy-manifest.json`. Pin that digest in tfvars.

## 6. What you must do and decide (checklist)

- Create the account, root MFA, SSO user, profile (steps 1.1-1.7).
- Choose region, bucket name, alert mailbox, ceiling, GitHub org/repo.
- Review and approve each plan; run each apply yourself (one explicit go-ahead per apply).
- Install `syft` and `trivy` or `cargo-audit` if you want an SBOM and audit in the release manifest; without them the
  manifest records them as skipped (it never fakes them).
- Decide NAT versus endpoints and Fargate versus EC2 for the engine task (cost) once the foundation modules exist.

## 7. Teardown notes

The state, trail and ECR resources are `force_destroy = false` and ECR is not force-deleted: emptying them is a
deliberate manual act. Do not delete the state bucket while any environment still uses it.
