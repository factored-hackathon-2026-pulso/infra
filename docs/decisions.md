# Decisions

Architecture decision records live in [adr/](adr/). Index:

| ADR | Decision |
|---|---|
| [0001](adr/0001-windows-and-external-services.md) | Windows-first tooling and external services |
| [0002](adr/0002-terraform-first-ownership.md) | Terraform-first ownership; nothing is applied by agents |
| [0003](adr/0003-agent-core-workload.md) | Agent Core as a deployed workload |
| [0004](adr/0004-llm-gateway-workload.md) | LLM gateway as a deployed workload |
| [0005](adr/0005-agent-core-escalado-fase-0-1.md) | Agent Core scale-out, phases 0 and 1 |
| [0006](adr/0006-data-pipeline-workload.md) | Data pipeline workload and data lake |
| [0007](adr/0007-hackathon-single-host-profile.md) | One cheap EC2 host per workload (core, platform, engine) for the hackathon |
| [0008](adr/0008-hackathon-free-plan-profile.md) | free_plan profile: container Postgres, no NAT, public CloudFront origins |

## Simplification decision (supersedes earlier choices for the account that will be created)

Binding input from the owner, recorded here instead of a new ADR because it changes defaults and operator workflow, not the architecture of ADR 0007:

- **One environment, `prod`**, region `us-east-1`, one new AWS account. Name prefix `pulso-prod`, tag `Environment = prod`. The old `staging` and `hackathon` environment names and the `us-east-2` or "no default region" choices no longer apply to this account.
- **No billing alerts, budget or monthly cap**, **no CI/OIDC role**, **no Organizations, no Identity Center** (not free, not needed for one account). The code for the budget, CloudTrail and the GitHub role still exists in `terraform/bootstrap` but is off and requires no input.
- **The human deploys from his machine** with a profile of an admin identity of the new account, using `scripts/aws-prod.ps1` (plan, saved plan, typed confirmation; never auto-approve).
- **Root user for now, IAM admin user later.** The owner chose to start with the root user's access key. Consequences and the three safety rules (MFA on root, key created only in the console and entered only with `aws configure --profile pulso-prod`, delete the key when done) are in [security-model](security-model.md); `aws-prod.ps1 check` warns without blocking. The safer alternative is an IAM user `pulso-admin` with `AdministratorAccess`.
- **Data loading is simple**: the human uploads to `landing/`; the loader runs on the engine host (`engine_host_can_load`, default true); the account's IAM users and root may upload and break glass by default. Core and platform hosts stay denied. There is no attempt to lock data access to one PC.
- **Everything else stays**: three hosts, private subnets, SSM only, deny-only bucket policy, KMS, one secret, WAF toggle, digest-pinned images.

## free_plan profile (record 0008)

Moved to [ADR 0008](adr/0008-hackathon-free-plan-profile.md).

Graduation path to a hardened setup: [security-model](security-model.md#graduation-path-when-this-becomes-more-than-a-hackathon).
