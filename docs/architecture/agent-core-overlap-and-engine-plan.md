# Agent Core overlap plan and engine platform plan

Status: working plan, written against `origin/main` at `c8a962e` and the open pull request #20
(`feat/agent-core-aws-fase0-1`, ADR 0005, CONFLICTING at the time of writing). Nothing here is applied.

Principle: this is one company platform. Where the Agent Core team's #20 declares a shared or Agent-Core-generic
piece, **their change stays** and we build on it. We do not keep a parallel module for the same concern.

## 1. What #20 covers and what we had in parallel

| Concern | #20 module | Our parked module | Decision |
|---|---|---|---|
| Network path (security groups) | `agent_core_network` | `core_stack` security groups | Theirs. Ours differs on purpose (see section 3) and is a review request, not a second module. |
| Image registry | `ecr` | none | Theirs. Engine images reuse `ecr` (one repository per image). |
| Connection pooling | `rds_proxy` | none | Theirs, Agent Core only. The engine does not need it yet. |
| Agent Core database | `database` (a separate instance) | `core_database` (shared instance, logical databases, grant contract) | Theirs for the instance. The **grant contract** (default privileges, CONNECT, REVOKE PUBLIC) is the one idea worth carrying over as a documented delta. |
| Blob, events, queues | `agent_core_data` | none | Theirs. |
| Ingress | `agent_core_ingress` (internal ALB + WAF) | none (Cloud Map, no ALB) | Theirs. ADR tension flagged in section 3. |
| Serve, relay, migrate, sweep, secrets, roles, autoscaling | `agent_core_workload` | `core_stack`, `core_secrets`, `workload`, `workload_iam` use | Theirs. Not duplicated. |
| Alarms | `agent_core_observability` | none | Theirs. |
| Agent Core exporter workload | none (they ship `relay` instead) | `core_stack` exporter | Open question 3. |
| AWS-API VPC endpoints | none (they open 0.0.0.0/0:443 for every role) | `core_vpc_endpoints` | Ours stays, as a shared opt-in module (used by the engine platform first). |

Files both branches touch (conflict surface): `terraform/envs/{staging,prod}/{main,variables}.tf`,
`docs/adr/0003-agent-core-workload.md`, `docs/architecture/deployment-status.md`, `docs/gaps/OPEN_GAPS.md`,
`tests/test_agent_core_scope_contract.py`, `terraform/modules/database/outputs.tf`. Our branch avoids all of
them: the env wiring lives in new files `terraform/envs/{staging,prod}/engine_platform.tf` and
`engine_platform_variables.tf` (Terraform loads every `.tf` in the root), so `main.tf` and `variables.tf` are
byte-identical to `origin/main` and the two branches merge in either order without a textual conflict.

## 2. Branch layout and order of operations

1. `claude/u-infra-core-stack-parked` (local only, never pushed): the earlier `core_database`, `core_secrets`,
   `core_stack` modules, their env wiring, review fixes and docs. Kept for reference and for the delta below.
2. `claude/u-infra-engine-platform` (from `origin/main`, the branch to push): `engine_platform`,
   `core_vpc_endpoints`, `workload_iam.pass_role_arns`, `network.private_route_table_ids`, env wiring behind two
   flags that default to `false`, tests, this document. It touches no file that #20 owns.
3. Merge in either order (no shared file; resource names do not collide: ours are `pulso-engine-*`,
   `<prefix>/engine/*` secrets, `/pulso/<env>/pulso-engine-*` logs, `<env>.pulso.internal`; theirs are `agent-core*`).
4. After #20 merges, rebase the engine branch, then open a small follow-up that (a) points
   `engine_platform.core_runtime_security_group_ids` and `core_callback_security_group_ids` at
   `agent_core_network.service_security_group_id`, (b) passes the shared Cloud Map namespace id if one exists,
   (c) applies the delta in section 4.
5. Never apply anything before the OIDC, state and authorization gaps in `docs/gaps/OPEN_GAPS.md` are closed.

## 3. Where we deliberately differ, and the tensions to resolve

1. **Ingress shape.** ADR 0003 item 2 says `pulso-core-runtime` is a private Cloud Map service with no ALB and no
   WAF; ADR 0005 declares an internal ALB and a WAF. Both cannot be the accepted text. Recommended default:
   keep #20's internal ALB for the Agent Core API (it answers the open ingress question and adds a rate limit)
   and record in ADR 0003 that item 2 is superseded for Core ingress, while engine services stay on Cloud Map.
2. **One shared service security group.** #20 puts `serve`, `relay`, `sweep` and `migrate` in one security group
   and gives all of them 0.0.0.0/0:443. A least-privilege split (per role) and VPC endpoints for the one-off and
   scheduled tasks is the stricter shape. Recommended default: accept their shape now, raise the split as a
   follow-up once the egress destination design exists.
3. **Sweep schedule enabled by default.** #20 defaults `sweep_enabled = true`. Recommended default: keep it, but
   with `serve_desired_count = 0` the sweep runs against an unmigrated database; require a human to enable it
   after the first migrate.
4. **Separate versus shared database.** ADR 0003 item 2 and #20 both say a separate instance. Our parked module
   defaulted to the shared instance. Recommended default: follow #20 (separate); revisit only with L10
   evaluation-load measurements.
5. **Egress to AWS APIs.** `core_vpc_endpoints` plus a prefix-list rule for S3 is needed by any workload whose
   security group does not allow 0.0.0.0/0 (the engine platform). It is optional for #20's workloads.

## 4. The delta that stays genuinely ours for Agent Core (held, rebased after #20)

- Grant contract for the Agent Core database roles, expressed as output/documentation: `REVOKE ALL ... FROM PUBLIC`,
  per-role `CONNECT`, and `ALTER DEFAULT PRIVILEGES FOR ROLE <owner>` for tables and sequences, so later
  expand-only migrations (agent-core ADR 0022) do not silently remove access from the runtime and exporter roles.
  Implemented and tested in the parked `core_database`; to be ported to whatever role model #20 settles on.
- Scheduler role least privilege: `ecs:RunTask` conditioned on the shared cluster ARN and `iam:PassRole`
  conditioned on `iam:PassedToService = ecs-tasks.amazonaws.com` (parked `core_stack`); a review request for
  `agent_core_workload`'s scheduler role.
- Exporter workload and the pulso-core-runtime service-JWT audiences and secrets (bridge service key, exporter
  key), if the exporter stays a separate workload (question 3).

## 5. Engine platform (our own infrastructure, this branch)

Source: V3 section 31 and plan annex D.5 (services control-api, worker, lab-broker, human-issuer, console), plan
16.13.2 and 16.16 flow rules, ADR 0003 flow matrix.

| Service | Treatment |
|---|---|
| control-api (also serves the `lab-broker` audience on its own route group) | Declared: ECS service, Cloud Map `control-api.<env>.pulso.internal`, one task role and execution role, one security group, own log group |
| worker | Declared: ECS service; may `ecs:RunTask` only the sandbox task, `iam:PassRole` only the two sandbox roles |
| migrate | Declared: one-off task |
| sandbox-lab | Declared: task definition only (launched by the worker), no secret, no database, VPC endpoints only |
| human-issuer | **Not declared**: local-only test issuer, refused in remote profiles |
| console (static delivery) | **Not declared**: depends on `edge`, which is `dependency_blocked` |
| lab-broker | No separate service: it is a route group of control-api (plan 16.11) |

Shared foundations are inputs (VPC, subnets, cluster, database security group, KMS, secret prefix); the module
creates no VPC, NAT, ALB, WAF, cluster or database instance. The existing single `improvement-engine` service in
`compute` is untouched; `engine_platform_enabled` defaults to `false`, so the plan is unchanged.

Secrets are names only, one entry per workload need (`engine/db-control-api`, `db-worker`, `db-migrate`,
`service-key-control-api`, `service-key-worker`, `verifier-keys`). The verifier entry holds the public keys of
the four distinct integration keypairs (binding callback, observations exporter, broker executor, human session
issuer) and is read only by control-api. No Core DSN, provider key or Jev key reaches any engine workload
(plan 16.17), enforced by a test.

Observability: running-task alarms for control-api and worker, only when a non-zero count is expected.

Provisional environment variable names, to be confirmed with the engine owners (CLQ-39): `PULSO_DATABASE_DSN`,
`PULSO_SERVICE_SIGNING_KEY`, `PULSO_VERIFIER_KEYS`, `PULSO_CORE_BRIDGE_URL`, `PULSO_SANDBOX_TASK`, and the
container commands (`worker`, `migrate`).

Not done here (gaps): ECR repositories for the engine and sandbox images (reuse `ecr` from #20), the OIDC deploy
and plan roles (`ci_roles`, blocked on inputs), engine queues or storage beyond PostgreSQL (none is required by
the spec read so far), metric-based alarms for jobs, ingest and budget (need the engine-to-infra metric
contract), the release manifest extension for the engine digests (`release/`), and the runbook update.

## 6. Questions for the user to relay to the Agent Core team

1. ADR 0003 item 2 (no ALB, no WAF) and ADR 0005 (internal ALB and WAF) disagree. Is the ALB the accepted
   ingress for Agent Core, and may ADR 0003 be amended to say so?
2. Will `agent_core_network` accept one security group per role (serve, relay, sweep, migrate) and VPC endpoints
   instead of 0.0.0.0/0:443 for the one-off and scheduled tasks?
3. Does Agent Core keep a separate `exporter` workload, or does `relay` plus the read-only export API replace
   it? Which of the two does the platform-observations path use?
4. Which database roles and grants will the bootstrap create on the separate instance? Can the default-privileges
   and CONNECT/REVOKE contract in section 4 be added to the bootstrap docs?
5. Is a shared Cloud Map namespace (`<env>.pulso.internal`) acceptable, and who creates it? Our modules take its
   id as an input so no second namespace is created.
6. Should `sweep_enabled` default to `true` before the first migrate has run?
7. Which environment variable names for key delivery (`identity-keys`, `staff-keys`) are final?
8. Do you want the ECR repositories created by `ecr` for the engine images as well, under one naming scheme?

## 7. Local verification

Terraform 1.16.4 was used locally (CI pins 1.10.5). Every module in this plan is exercised with mock providers;
see the verification section of the journal entry in `BITACORA_PULSO.md`. No plan or apply was run against an
account.
