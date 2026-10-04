# AWS staging asks (TA0)

Nothing here is applied. Every row is a decision or value the owner must relay before the first real
`terraform plan` (TA3). Principles: one company with shared foundations; the agent-core infra owner (jzapata)
owns any shared account, state bucket, VPC and KMS; this repository consumes them and never duplicates them
(ADR 0002, 0003). Values are never written in Git: account ids, ARNs and keys go in an ignored tfvars file or
approved CI configuration. Secrets are listed by NAME only; values are set out-of-band by a human.

Plan IDs: ASK-17..21 and ASK-24 already exist in the plan; AWS-nn rows are the detail behind them.

| Id | Ask | Needed for | Safe default if unanswered | Stays blocked |
|---|---|---|---|---|
| AWS-01 (ASK-17) | Staging AWS account id (kept out of Git) and SSO profile name | any plan against a real account | offline validate only | TA3-TA6, LAB28, GTA |
| AWS-02 (ASK-17) | Region (ADR 0003 says `us-east-1` for now; confirm) | `aws_region`, AZ list, endpoint/model availability | no region committed; variable has no default | TA3 |
| AWS-03 (ASK-18) | Role to assume for plan and a separate one for apply; trust via SSO or GitHub OIDC; permissions boundary ARN for `least_privilege_policy_boundary` | `ci_roles`, human-approved apply | no role, so no real plan runs | TA3, TA4 |
| AWS-04 (ASK-18) | Who owns shared foundations (VPC, KMS, state) and whether staging reuses them or gets its own VPC; relay via the agent-core infra owner | avoid duplicating shared infra | assume the agent-core infra owner owns them; defer, plan only | TA3 |
| AWS-05 (ASK-18) | Terraform state: S3 bucket name, key prefix, lock approach (`use_lockfile`), KMS for state | `backend.hcl` (kept outside Git) | `backend.hcl.example` placeholder, `-backend=false` | any init with remote state |
| AWS-06 (ASK-20) | Monthly spend ceiling (USD) and AWS Budgets thresholds (50/80/100 %) | budgets, kill-switch, NAT/endpoint cost choices | no apply; cheapest `nat_strategy`, `private_endpoints_enabled` off | TA6, any apply |
| AWS-07 (ASK-19) | Alarm mailbox a human reads (SNS subscription confirmed) | `alarm_actions`, TA6 alarm drill | unconfirmed alarm; TA6 red | TA6 |
| AWS-08 | KMS: reuse an existing customer-managed key ARN or allow a new one per env; key admins and users | `kms_key_arn` for RDS, Secrets Manager, S3, ECR | AWS-managed keys; `kms_key_arn` left empty | CMK posture only |
| AWS-09 | S3 names (globally unique): source, artifact, Core blob (agent-core ADR 0023), data lake raw/curated; retention and lifecycle | `source_bucket_name`, `artifact_bucket_name`, `core_blob_bucket_name`, `data_lake` | no names committed; no bucket created | storage, lake, data pipeline |
| AWS-10 | ECR: confirm repo names `<env>/pulso-engine`, `<env>/pulso-core`, platform-exporter; CI may push by digest | `engine_ecr_enabled`, `bridge_ecr_enabled`, image digests | switches stay false; no image | all workloads (TA4, TA5) |
| AWS-11 | RDS/Aurora PostgreSQL: engine/version, instance class, multi-AZ, backup days, final snapshot, deletion protection; separate DBs for engine, Core runtime/eval, platform | `database_*` variables | smallest class, single AZ, deletion protection and final snapshot on | database, migrate |
| AWS-12 | ECS/Fargate sizing and desired counts for control-api, worker, core-runtime, core-exporter, platform-exporter, llm-gateway; who runs the gateway (ours or agent-core) | `desired_count`, `bridge_*_desired_count`, engine platform | all counts 0; `engine_platform_enabled` and `bridge_services_enabled` false | TA4, TA5 |
| AWS-13 | Networking: VPC CIDR, 2+ AZs, subnet CIDRs, NAT per AZ or single, private endpoints on/off, no public ingress, service-discovery namespace | `network`, `core_vpc_endpoints` | no public endpoint, no ALB, `assign_public_ip=false`; CIDRs only after the owner confirms no overlap | any apply |
| AWS-14 | Secrets Manager entries by NAME under `secret_name_prefix`: `<env>/db_app`, `<env>/db_exporter`, `<env>/identity_keys`, `<env>/staff_keys`, `<env>/bridge_service_key`, `<env>/llm_gateway_token`, `<env>/runtime` (proposed names; values set by a human, never in Terraform or Git); confirm an application-role DB secret that is not the RDS master | `runtime_database_secret_arn`, `bridge_core_secret_arns` | metadata only; no values; tasks cannot start | workloads starting |
| AWS-15 (ASK-8/9) | Model provider: provider/region, model access (for example Bedrock model ids, or a hosted key held as `<env>/llm_provider_key`), hard spend cap, and whether treated E0 payloads may go to a hosted model (default NO) | llm-gateway `LLM_ENDPOINTS`, hosted-real rung | stand-in/roleplay and replay only; no hosted calls | DEMO-2 hosted rung |
| AWS-16 | DNS: hosted zone and domain, or confirm internal-only service discovery | control-api/gateway URLs for TA5 | internal only; no zone, no certificate | any public URL |
| AWS-17 (ASK-21) | Approval of each apply of a saved plan (one sentence per apply, plan sha recorded) | TA4 and later | no apply | TA4+ |
| AWS-18 (ASK-24) | Relay EXT-1 to agent-core (pin hygiene, c814c2b Dockerfile and runbook, Jev on main) | TA5 | plan without them, no Core-side Jev | TA5 accuracy |
| AWS-19 | Data pipeline (ADR 0006): enable now or defer; a `data_pipeline_enabled` env switch must exist first (see gaps) | data lake, pipeline task | off | data lake, reader roles |

| AWS-20 | Logging and retention: CloudWatch log retention days per log group, who reads logs, CloudTrail/Config owned by the shared account owner (reuse, do not duplicate); S3 and RDS backup/retention policy | `log_retention_days`, backup variables | shortest retention that keeps TA6 evidence; reuse shared trail | TA6 |
| AWS-21 | Break-glass: who may assume an emergency admin role, how it is logged and reviewed (owned by the shared account owner; this repo creates none) | incident response | no break-glass role created here | any apply |

Count: 21 asks (8 map to existing ASK ids). Minimum to unblock a first plan: AWS-01 to AWS-05.
