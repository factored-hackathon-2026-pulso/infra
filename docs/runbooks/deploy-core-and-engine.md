# Runbook: deploy and roll back Agent Core and the engine (manual)

**Status:** procedure for an authorised human operator. Nothing here is automated, no auto-deploy exists, and
the offline tools (`release/validate_manifest.py`, `release/validate_plan.py`, `release/deploy_plan.py --dry-run`)
never call AWS. Every command marked **[human authorisation]** changes AWS state and must only be run by a person
who holds that authority. A passing offline check is not evidence of a deployment.

## 1. External inputs (must exist before step 0)

| Input | Owner | If missing |
|---|---|---|
| GitHub OIDC provider ARN and exact `github_subjects` (plan, apply, deploy) | AWS account admin | `ci_roles` stays at `count = 0`; apply by a human with their own approved access |
| Remote state bucket, lock and KMS | AWS account admin (bootstrap) | Stop; do not init a local backend for staging/prod |
| Loaded secret values (`pulso_runtime`, Core DSN/keys/JEV/LLM) | Secret owners | Stop; Terraform never writes values |
| Permissions boundary and approved apply policy | Security owner | `ci-apply` and `deploy` roles are rejected by their preconditions |
| Image digests for engine and Core | Engine / agent-core CI | No manifest can be built |
| Named approver | Release owner | `approvals[]` empty means no deployment |

## 2. Pre-checklist

1. Build `deploy-manifest.json` for the target environment (`staging` or `prod`; never anything else).
2. `python release/validate_manifest.py deploy-manifest.json` exits 0 (rules M-01..M-10).
3. `terraform show -json <saved plan> > plan.json`, then
   `python release/validate_plan.py plan.json --manifest deploy-manifest.json --stage infra` exits 0.
   `--stage infra` rejects any plan that changes a service task definition: a service must never roll before
   `core-migrate` (step 3). Service digests change only in the separate rollout plans of steps 5 and 7, validated with
   `--stage rollout`; each such plan needs its own `infra.plan_digest` and approval.
   If the plan updates or replaces an RDS instance, take the step 2 snapshots before applying it.
   A delete or replace of RDS, secrets or KMS fails unless the operator passes `--allow-delete <address>` after a
   conscious decision.
4. The approver records an approval pinned to the manifest digest (`validate_plan.manifest_digest`) and
   `infra.plan_digest` equals the digest of the plan about to be applied.
5. `python release/validate_plan.py plan.json --manifest deploy-manifest.json --mode apply` exits 0.
   Apply mode refuses without an approval pinned to this manifest, and refuses a plan that differs from the approved one.
6. `console.image_digest` is `null` (reason `dependency_blocked:edge`). Do not deploy with a console image.
7. `python release/deploy_plan.py --dry-run deploy-manifest.json` prints `completed` (rehearses order only).

## 3. The nine steps

| # | Step | Command / action | Expected | Stop when |
|---|---|---|---|---|
| 0 | Validate manifest and plan | Section 2 | exit 0 | Any non-zero exit; nothing changed |
| 1 | Apply the validated plan **[human authorisation]** | `terraform apply <saved plan>` (only if the plan has a diff) | Applied plan digest equals `infra.plan_digest` | Apply error; services untouched |
| 2 | Manual RDS snapshots, Core and Pulso **[human authorisation]** | `aws rds create-db-snapshot ...` | Snapshot ids noted for the receipt | No snapshot: do not migrate |
| 3 | `core-migrate` **[human authorisation]** | `aws ecs run-task` for the `core-migrate` task definition with the manifest image | exit code 0, `schema_digest` equals the manifest | Non-zero exit: see section 5 |
| 4 | Schema smoke with the read-only role | Check the fixed table list for the `schema_digest` | All tables present | Missing table: stop |
| 5 | Update `pulso-core-runtime` **[human authorisation]** | New plan/apply with the new digest (never a manual service edit) | Circuit breaker holds, `/readyz` returns 200 | Service rollback (section 4) |
| 6 | `engine-migrate` **[human authorisation]** | Run the migrate task with the engine image | exit 0, `migrations_head` equals the manifest | Stop; Core is already at N (section 4) |
| 7 | Update `core-exporter`, then engine api and worker **[human authorisation]** | New plan/apply with the new digests | Health OK and `GET /internal/v1/version` shows the manifest SHA | Service rollback |
| 8 | Seed, `registry-wire-contract`, bounded E2E | Run the suite against the real environment | `smoke.result = "ok"`, `doubles = []` | Joint rollback |
| 9 | Receipt | Archive manifest, smoke, approver, snapshot ids, plan digest in a private location | Stored, no secrets | n/a |

Smoke counts as success only when `target = real_aws`, `doubles` is empty and `result = "ok"`. A result of `not_run`
is never presented as success, and a `--dry-run` never is.

## 4. Rollback

Rollback is a new plan with the previous manifest (digest pair reverted as a unit). It is a new plan, so it needs its
own `infra.plan_digest` and an approval pinned to the manifest being applied; validate it with `--mode apply --stage rollout`. Roll services back in reverse order (engine api/worker, exporter, then Core runtime). Never edit an ECS service by hand:
the circuit breaker reverts the task definition but Terraform state still points to the new one.

Decision tree "is the schema compatible?":

1. `core-migrate` failed: nothing to roll back. Services are intact. Go to section 5.
2. Core readiness failed after migrate: the schema N must work with the image N-1.
   - `compat.kind = unchanged` or `expand` with `n_minus_1_image_tested = true`: redeploy Core N-1 via a new plan.
   - Otherwise: freeze at N and fix forward.
3. Engine failed after Core N: restore (Core N-1, engine N-1) only if Core schema N contains N-1 **and** the engine
   migration class is `expand`. Otherwise freeze at N and fix forward.
4. A `contract` migration on either side is blocked at validation without an explicit strategy (M-08). Data is never reverted.

A PITR or snapshot restore is a separate human decision: it loses later receipts and is not automatic rollback.

## 5. `core-migrate` failure handling

`agentcore migrate` is idempotent (`CREATE ... IF NOT EXISTS`) and has no versions and no `down`.

1. Stop. Do not run steps 5 to 8. The orchestrator marks the run `blocked` at `core_migrate` and issues no service update.
2. Read the task logs in the `/pulso/<env>/` log group (observability reader role) for the exit reason. Do not paste
   connection strings or secrets into tickets.
3. Classify:
   - Connectivity or credentials (`core_owner` DSN, security group, secret not loaded): fix the input and re-run the task.
     The migration is idempotent, so re-running is safe.
   - Schema conflict with a pre-existing object: a human decides; if a snapshot restore is considered, it is a separate decision.
   - Timeout or resource exhaustion: re-run once with the same image; if it fails again, stop and escalate.
4. Confirm the snapshot id from step 2 is in the receipt draft before any restore discussion.
5. The deployment stays `blocked` until a re-run exits 0 and `schema_digest` matches.

## 6. What NOT to do

- Do not edit services, task definitions or desired counts by hand.
- Do not restore PITR or a snapshot without an explicit human decision.
- Do not put master secrets in a runtime or execution role (the RDS master secret is rejected by Terraform and by the plan checks).
- Do not deploy with `console.image_digest` set or with `AGENTCORE_ALLOW_DEMO` anywhere (rejected by the `workload` module and by `validate_plan.py`).
- Do not deploy a mutable tag; images must be `repo@sha256:<64 hex>`.
- Do not claim an environment is deployed or authorised from Terraform declarations or offline checks.

## 7. Receipt contents

Manifest and its digest, approver and time, plan digest, snapshot ids, per-step result, smoke block (suite, target,
doubles, result), rollback target (`previous_manifest_digest`), and the list of inherited blockers below. No secrets and no PII.

## 8. Inherited blockers (stay `dependency_blocked`)

Debug ingress and edge, runtime DB role and secret bootstrap, secret recovery path, controlled egress, engine metrics
contract, OIDC provider and subjects, state/bootstrap, CLQ-43 sandbox, manifest signing. See `docs/gaps/OPEN_GAPS.md`.
