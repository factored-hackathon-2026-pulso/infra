# The data pipeline as a deployed batch workload

Status: **Proposed**. Accepting the ADR creates no resources: see "Implementation status".

## Context

`pulso-factored/data-pipeline` is a new repository: a dbt + DuckDB pipeline with a medallion layout (bronze,
silver, gold) that turns the challenge dataset (S3, 13 tables), the E0 sample and, later, the Platform CC
`event_log` into clean, classified data for Agent Core and for analysis. Its design and data-governance notes
are in that repository (`docs/00-plan-v1.md`, `docs/02-gobierno-de-datos.md`).

It is the data/ETL system that `agent-core` ADR 0002 names as a separate system with its own owner, and the
producer of the two interfaces Agent Core expects from it: per-customer read-models and a field-classification
catalog (`FieldClassification`, agent-core ADR 0008).

Unlike the three existing workloads it is **not a service**. It runs to completion, on a schedule or by hand,
and writes immutable publications to S3. It holds personal data at rest in several sensitivity zones, which is
what makes this ADR mostly about access, not about compute.

## Decision

1. **Scope.** This repository owns the Terraform/AWS infrastructure that *runs* the pipeline. It does not own
   the pipeline's code, image build, data contracts or the meaning of any column; those stay in `data-pipeline`.
2. **Shape.** A fourth *workload*, a batch task: one ECS/Fargate task definition (`create_service = false`),
   started by EventBridge Scheduler through the existing `scheduled_task` module and by a manual
   `ecs run-task`. It has no listener, no load balancer and no inbound path.
3. **Data plane.** One S3 bucket for the lake, KMS-encrypted, versioned, public access blocked, with these
   prefixes. The access matrix below is the reason for the split, so each prefix gets its own IAM statements:

   | Prefix | Content | Written by | Read by |
   |---|---|---|---|
   | `bronze/` | faithful copy of the sources, includes personal data and untreated free text | pipeline task | pipeline task only |
   | `bronze_eval/` | the evaluator's answers (`labels`, `timeline`) | pipeline task (E0 one-off) | the evaluator only |
   | `publish/<run_id>/gold_restricted.duckdb`, `field_classification.json` | personal data in clear, classified | pipeline task | Agent Core runtime (read-model tools) |
   | `publish/<run_id>/gold_masked.duckdb` | read-models with masked personal data | pipeline task | analysts that do not go through Agent Core |
   | `publish/<run_id>/gold_analytics.duckdb`, `parquet/` | pseudonymised, no direct identifiers, no labels | pipeline task | analysis, ML, dashboards |
   | `publish/latest.json` | pointer to the current run | pipeline task, last | every consumer |

   The re-identification map (`pseudonym_map`) is **never written to S3**: it exists only in the task's
   ephemeral scratch and in the pseudonymisation key.
4. **Identity.** A task role that can read and write only this bucket, read the challenge dataset, read its own
   two secrets and use the bucket's KMS key; one execution role limited to its own secrets and log group. Each
   consumer gets a read role scoped to the prefixes in its row of the matrix. No role may read `bronze/` except
   the task, and nothing may reference the RDS master secret (the guard in `workload_iam` applies).
5. **Egress.** The challenge dataset is in another account and in `us-east-2`, while the foundation is
   provisionally `us-east-1`. A gateway endpoint covers only same-region S3, so reading the dataset is an
   external dependency that needs the `controlled_nat` profile with a destination-controlled path to
   `s3.us-east-2.amazonaws.com`. Reading and writing the lake bucket and Secrets Manager can use private
   endpoints. The pipeline needs no model-provider egress.
6. **Secrets.** Terraform provisions entries (names and encryption only); values are set out of band, as in
   ADR 0003:

   | Entry | Content |
   |---|---|
   | `data-pipeline/pseudonym-key` | the HMAC key for pseudonyms |
   | `data-pipeline/dataset-reader` | read-only credentials for the challenge bucket, issued by the organisers |

   Rotating the pseudonym key changes every pseudonym, so a rotation is a planned re-publication, not a routine
   action. A `kid`-based rotation scheme is open in `data-pipeline`.
7. **Retention.** Publications are immutable and about 1 GB each at the current scope, so the lake bucket needs
   a lifecycle rule for old `publish/` runs (keep the last N and `latest.json`'s run). The retention period for
   `bronze/` (personal data at rest) is a **data-owner decision this repository does not take**: see the gap.
8. **Environments, region, apply.** Unchanged: `staging` and `prod` only, `us-east-1` provisionally, and no
   automated apply.

## Interface contract between the repositories

Both sides must change this table in the same pair of pull requests.

1. **Image.** `data-pipeline` publishes an immutable digest (non-root uid 10001, DuckDB `httpfs` preinstalled so
   the task needs no internet to load extensions). This repository deploys only a digest, never a tag.
2. **Command.** `python -m pipeline.run`. Default steps: `ingest_bank,build,publish`. `ingest_e0` is a one-off
   manual step (the E0 sample is restricted) and is not in the scheduled run.
3. **Configuration**, injected as environment variables:

   | Variable | Kind | Content |
   |---|---|---|
   | `PIPELINE_ROOT` | plain | `s3://<lake bucket>/<prefix>`; selects the dbt `s3` target |
   | `WORK_DIR` | plain | `/work`, the scratch for `warehouse.duckdb`, `target/` and the publication staging |
   | `DATASET_BUCKET`, `DATASET_PREFIX`, `AWS_DEFAULT_REGION` | plain | the challenge dataset location and its region (`us-east-2`) |
   | `S3_KMS_KEY_ID` | plain, optional | SSE-KMS key for uploads; the bucket default otherwise |
   | `PSEUDONYM_KEY` | secret | from `data-pipeline/pseudonym-key` |
   | `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` | secret | from `data-pipeline/dataset-reader`, only while the dataset account issues keys |

   The task exits non-zero before doing any work when `PIPELINE_ROOT` or `PSEUDONYM_KEY` is missing, naming the
   variable but never its value.
4. **Outputs.** `publish/<run_id>/` with `gold_analytics.duckdb`, `gold_masked.duckdb`, `gold_restricted.duckdb`,
   `parquet/`, `field_classification.json` and `release.json`; `publish/latest.json` is written **last**. A
   `run_id` that already exists is refused, so a retry cannot overwrite a publication.
5. **Failure semantics.** `dbt build` failing means nothing is published and `latest.json` does not move. A
   retry is safe: bronze ingestion is incremental by object ETag and publications are immutable.
6. **Resources.** Measured on the current scope (customers, products, complaints, transactions, exchange rates
   and E0, about 0.3 GB of bronze): `warehouse.duckdb` is 1.5 GB and one publication about 1 GB, so the task needs
   roughly 4 GB of ephemeral storage, inside Fargate's 20 GiB default for now. A `build` took about 85 seconds on a
   developer laptop, and the first load of `transactions` added about 30 seconds. **CPU and memory are not measured on Fargate and no number is asserted here.** The
   remaining fact tables (`digital_events` alone is 3.7 GB of CSV) will change all of these.
7. **Observability.** The runner prints the step names and counts, never row data or secret values. A metric
   contract (freshness, quarantine rate, run duration) is open.

## Implementation status

Nothing for the data pipeline is declared in Terraform and nothing is deployed.

- **Delivered in `data-pipeline`:** the runner, the `Dockerfile` (verified: a full `dbt build` of 161 checks
  and the publication ran inside the container with `--network none`), the guarded publication to S3 (checked
  against a simulated client, not against real S3) and the data-governance document.
- **Missing in `data-pipeline`:** an image CI that publishes a digest; the remaining fact tables; the
  Platform CC `event_log` source; key rotation.
- **Missing here:** ECR repository, the lake bucket and lifecycle, the task definition pinned to a digest, the
  two roles and the consumer read roles, the secret entries, the schedule, the egress design for the dataset
  account, and the alarms. `terraform` was not available where this ADR was written, so no HCL was drafted:
  declaring unvalidated modules in this repository would break its credential-free CI gate.

## Consequences

- On acceptance, AGENTS.md, CONTEXT.md and the README will name the pipeline as a workload of this repository; they are
  not changed while the ADR is only proposed.
- The first slice is the lake bucket and its access matrix, because the protection of the personal data is
  enforced there and nowhere else (DuckDB has no roles).
- It is the first workload with data at rest in different sensitivity zones inside one bucket. If a prefix-level
  policy proves too coarse, the alternative is one bucket per zone; this ADR starts with prefixes to keep the
  foundation small.
- A fourth image to build and deploy, but a task that exits, so there is no always-on cost or surface.

## Open questions

- Retention of `bronze/` and the right-to-erasure path for personal data at rest (a data-owner decision;
  per-subject keys with crypto-shredding is the production design named in agent-core ADR 0008, not implemented).
- One bucket with prefixes (assumed) or one bucket per sensitivity zone.
- Who issues and rotates the read-only credentials for the challenge dataset, and whether the organisers can
  offer a role instead of long-lived keys.
- How the Platform CC `event_log` reaches the task: a read-only database role (assumed in `data-pipeline`), an
  export endpoint or a queue. A database role needs a network path and a secret this repository would provision.
- Size, schedule frequency and alarms: not measured, so none are asserted.
