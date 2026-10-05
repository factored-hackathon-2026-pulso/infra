# Automatic data loader (landing -> lake, on the engine host)

Decision of 2026-10-05: data loading runs automatically in AWS. `engine_host_can_load` now defaults to `false`: the engine host
role itself has NO access to `landing/`, `lake/bronze/` or the restricted gold. Loading is done by a dedicated role that the
engine host can assume only inside one systemd one-shot. Switch: `auto_loader_enabled = true` (default off; needs
`images.engine.pipeline`, the digest of the data-pipeline image, and the secret key `LOADER__PSEUDONYM_KEY`). Nothing here is
applied; Terraform is checked with mocked providers and the scripts with static and unit tests.

## Flow

```
operator (IAM user/root)
  1. aws s3 sync raw tables  -> s3://<bucket>/landing/bank/      (SSE-KMS, PUT only)
     aws s3 sync E0 package  -> s3://<bucket>/landing/e0/
  2. aws s3 cp READY.json    -> s3://<bucket>/engine/inbox/READY.json     LAST

engine host, pulso-loader.timer (every 5 min) -> pulso-loader.service (one-shot, loader.env only)
  a. read the marker with the HOST role (engine/* is host-readable; the marker holds names and checksums, no data)
  b. run key = first 16 hex of sha256(marker); sts:AssumeRole(loader role, ExternalId) -> 0600 file under /run (tmpfs)
  c. lake/loader/done/<key>.json exists? -> exit 0 (same marker never reloads, also after a host replacement)
  d. optional cells export (LOADER_CELLS_CMD) + k>=10 gate: a failing gate stops the run BEFORE anything is published
  e. docker run data-pipeline: ingest_bank (+ ingest_e0), dbt build, publish -> bronze, silver, gold_masked, gold_analytics,
     gold_restricted, lake/publish/<run>/..., latest.json LAST (the pipeline's own publish step)
  f. cells -> lake/gold_analytics/bank_cells/<key>/{cells.ndjson,MANIFEST.json}, then bank_cells/latest.json
  g. done marker, status engine/loader/status/last.json, credentials file removed (trap)
```

`READY.json` example (names and sha256 only): `{"dataset":"bank","e0_prefix":"landing/e0/","files":{"landing/bank/customers.parquet":"<sha256>"}}`.
Change the content (new checksums) to trigger a new load; re-uploading identical bytes is a no-op.

Why a timer that polls a marker: S3 event notifications need an SQS queue or EventBridge rule plus a consumer on the host anyway;
a 5-minute poll of one tiny object costs nothing, needs no new resource, survives host replacement (state lives in S3) and is the
simplest robust option on a free-plan EC2. Latency is at most 5 minutes.

## Credentials and isolation

- Role `<name_prefix>-loader`: trust = ONLY the engine host role, with `sts:ExternalId` (`<name_prefix>-loader-<account>`); one-hour
  sessions; the host permissions boundary. Policy: read `landing/*` and `lake/*`, write `lake/*`, list those prefixes, KMS use of the
  data key. No Secrets Manager, SSM, ECR, IAM or STS. The bucket policy lists the role as a loader, so the PII Deny statements exempt
  exactly this role.
- The engine host role gets `sts:AssumeRole` on that one role (identity policy and boundary). Nothing else changes for it.
- The credentials live in a `0600` file under `/run/pulso/loader/` and in subshells/containers started by the script (`with_loader`,
  `--env-file`). They are never exported in the script's shell, never written to `/srv/stack/.env`, never in `pulso.env`, and the
  engine containers read only `common.env` and `pulso.env`. Loader values (`LOADER__*` secrets, `/pulso/engine/loader/*` SSM) are
  rendered to `loader.env`, which only `pulso-loader.service` reads (`EnvironmentFile=`). Tests pin all of this.
- `PSEUDONYM_KEY` (the pipeline's HMAC key): secret key `LOADER__PSEUDONYM_KEY`, set out of band; the run refuses `CHANGE_ME`.
  Rotating it changes every pseudonym (a planned re-publication).

## Failure, alerting, limits

- Failure: the script exits non-zero, `systemctl status pulso-loader` shows `failed`, `journalctl -u pulso-loader` has the lines,
  `engine/loader/status/last.json` holds `{state, run, at, detail}` (no data), and `pulso-loader-failed.service` leaves
  `/srv/data/loader/FAILED` (removed by the next good run). Shipping journald to CloudWatch or an SNS topic is a follow-up (the
  CloudWatch agent here ships docker logs only).
- Limits: the pipeline runs with `docker --memory` and `--cpus` (defaults 1g and 1.0; variables `loader_memory`, `loader_cpus`),
  and the unit has `Nice=10`, `IOSchedulingClass=idle`, `CPUQuota=100%`, `MemoryMax=512M` (the unit cgroup holds the script; docker
  puts the container elsewhere, hence the docker flags).
- Sessions last at most one hour; a longer run fails (re-run after raising the pipeline speed or splitting steps).

## k>=10 gate for bank_cells

`check_cells_k.py` fails the run (exit 3) when any cell has `denominator < 10`, a count that is not a non-negative integer,
`numerator > denominator`, a key outside `{metric, dims, half, period, numerator, denominator}` (no ids, no free text), malformed JSON,
or when the file is empty. It prints counts only. It runs on the cells BEFORE the pipeline publishes, so a failing gate leaves the lake
untouched ("fail the run, not the data"). `LOADER_CELLS_CMD` (variable `loader_cells_cmd`) is the producer: a command that writes
`$CELLS_OUT`; with the default empty value the run has no cells export. The producer (the engine's `bank_cells.py` over the raw
tables) and its image are an open item (ask to the engine lane).

## Memory fit and sizing

Numbers from the data-pipeline repo (README and `dbt/profiles.yml`): the dataset is about 5.3 GB of CSV (13 tables, facts partitioned
by day), a full build takes 6 min 18 s on a laptop with ONE dbt thread (17 min 46 s with four: they fight for cores and memory), and
there is NO memory profile (no peak RSS, no `memory_limit`, no `temp_directory`; CPU and memory on Fargate "remain unmeasured").
So every figure below is UNMEASURED; this is a bounded design, not a measurement.

What the loader does to bound memory:
- one container, one dbt thread (`DBT_THREADS=1`), `docker --memory` (default 1g) and `--memory-swap` equal to it (hard cap: an OOM
  kills the run visibly, the lake is untouched because `latest.json` moves last);
- DuckDB `memory_limit` (`loader_duckdb_memory`, default 2GB) and spill to `DUCKDB_TEMP_DIRECTORY` on a bind mount of the data volume
  (never a RAM-backed tmpfs). UNVERIFIED: the pipeline profiles do not read these variables yet (ask below);
- optional table batches (`loader_table_batches`): one short container per `ingest_bank --tables <batch>`, so ingest peak memory is
  one batch. UNVERIFIED contract;
- a 4 GiB swap file on the data volume (`loader_swap_gb`, only on a loader host) as a safety net.

Sizing (Free Tier eligible types in the free_plan profile: c7i-flex.large 4 GiB, m7i-flex.large 8 GiB, t3.small and t4g.small 2 GiB,
t3.micro/t4g.micro/t8i.micro 1 GiB, t8i.small 2 GiB):
- `t3.small` (2 GiB) with the engine (about 576 MiB of limits) leaves about 1.2 GiB: DuckDB over 5.3 GB of CSV will spill heavily,
  rely on swap and probably fail or take hours. Not recommended.
- `c7i-flex.large` (4 GiB, 2 vCPU) is the smallest eligible type that plausibly fits with `loader_memory = 2g`..`2500m`,
  `loader_duckdb_memory = 1500MB` and spill. It is the default engine type when `auto_loader_enabled` is on. UNMEASURED.
- `m7i-flex.large` (8 GiB) is the safe choice; it costs the same class as the core host.
- If none works in a measured run, the user must choose between (a) a bigger instance only for the loader window (set
  `instance_types.engine` for the load and back after, a replacement of the host), or (b) option B, an ephemeral loader instance
  or task started per load (also removes the assume-from-the-engine-host risk). The first measured run decides; log peak RSS with
  `docker stats` and the pipeline's own timings.

## Unverified contracts and the ask to the data-pipeline owners

Marked UNVERIFIED because the pipeline code was not run here: `--steps ingest_bank,build,publish` (and `ingest_e0`) via
`python -m pipeline.run`; `python -m pipeline.ingest_bank --tables <csv>`; reading `landing/` through `DATASET_BUCKET`/`DATASET_PREFIX`
with the standard AWS chain (no `DATASET_AWS_*`); `E0_SOURCE_DIR`; `DUCKDB_MEMORY_LIMIT`/`DUCKDB_TEMP_DIRECTORY`; and
`LOADER_CELLS_CMD` (the bank_cells producer, which lives in the engine repo as `scripts/aggregate/bank_cells.py` and is not in the image).

Ask (data-pipeline): (1) `profiles.yml` settings `memory_limit: "{{ env_var('DUCKDB_MEMORY_LIMIT', '2GB') }}"` and
`temp_directory: "{{ env_var('DUCKDB_TEMP_DIRECTORY', '/work/duckdb_tmp') }}"` for dev and s3 targets; (2) a measured peak-RSS and
duration table for a full build (13 tables) with `memory_limit` 1.5/2/3 GB on 2 and 4 vCPU; (3) confirm `pipeline.run --steps` names
and that `ingest_bank --tables` per table or batch yields the same warehouse as one run; (4) confirm `PIPELINE_ROOT=s3://...` writes
`publish/<run>/` with `latest.json` last and that `parquet/` holds analytics-zone data only; (5) a `cells` step or documented command
that produces the bank_cells NDJSON (or a statement that the engine repo owns it and the image to use).

## Residual risk (honest)

- The engine host role can assume the loader role. A compromised engine process, or any container on that host that can reach IMDS
  (hop limit 2 since PR 39 so that containers can use the instance profile), can obtain host credentials and assume the loader role for
  up to an hour, reading `landing/` and the restricted gold. The ExternalId is not a secret and does not stop that. This is the price of
  option A; option B (a separate loader host or a Step Functions/ECS task triggered from S3) removes the assumption path and is the
  upgrade. Mitigations to consider: block the metadata address for the engine container, shorter sessions, a CloudTrail alarm on
  `AssumeRole` of the loader role outside the timer's cadence.
- The pipeline container sees the loader credentials and the pseudonymisation key in its environment for the run.
- The full build on the engine host is unmeasured and shares CPU credits and memory with the engine.
- `--steps` and the E0 handling follow the data-pipeline README (`python -m pipeline.run --steps ...`, `E0_SOURCE_DIR`,
  `DATASET_BUCKET`/`DATASET_PREFIX`/`DATASET_REGION`, `PIPELINE_ROOT=s3://<bucket>/lake`); not run end to end here.
- `labels`/`timeline` (evaluator zone, `bronze_eval/`) are not produced by this loader.

## Operate

```bash
sudo systemctl list-timers pulso-loader.timer
sudo systemctl start pulso-loader.service          # run now (needs the marker)
journalctl -u pulso-loader -n 100 --no-pager
aws s3 cp s3://<bucket>/engine/loader/status/last.json -    # from a machine with access
```
