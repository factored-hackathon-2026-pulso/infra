#!/bin/bash
# Pulso automatic data loader (engine host). Run by pulso-loader.service (timer every 5 minutes). Never prints secret values.
#
# Flow: poll the inbox marker with the HOST credentials -> compute the run key (sha256 of the marker) -> assume the loader role
# (STS, external id) -> skip if lake/loader/done/<key>.json exists (idempotent) -> cells export (run-bank-cells.sh: bank_cells.py in a
# credential-less engine-image container over landing/bank) + k>=10 gate (a failing gate fails the run BEFORE anything is published)
# -> cells staged under bank_cells/<key>/ -> re-assume (fresh 1 h session) -> data pipeline container (bronze, silver, gold_*; it
# publishes lake/publish/<run>/ and moves latest.json last) -> bank_cells/latest.json LAST -> done marker -> drop the credentials
# (trap removes the 0600 file under /run).
# The loader credentials exist only in the file $CREDS and in subshells/containers started by this script; they are never exported in this
# shell, never written to the stack .env, never in the engine containers' environment.
set -euo pipefail
umask 077

: "${LOADER_ROLE_ARN:?}" "${LOADER_EXTERNAL_ID:?}" "${LOADER_BUCKET:?}" "${LOADER_REGION:?}" "${PSEUDONYM_KEY:?}"
case "$PSEUDONYM_KEY" in CHANGE_ME|"") echo "loader refused: LOADER__PSEUDONYM_KEY is unset or still CHANGE_ME" >&2; exit 78 ;; esac
LOADER_MEMORY="${LOADER_MEMORY:-1g}"
LOADER_CPUS="${LOADER_CPUS:-1.0}"
LOADER_DUCKDB_MEMORY="${LOADER_DUCKDB_MEMORY:-2GB}"   # DuckDB memory_limit; the docker --memory cap is the hard stop above it
LOADER_TABLE_BATCHES="${LOADER_TABLE_BATCHES:-}"        # e.g. "customers,marketing_campaigns;transactions": ingest_bank batch by batch, fresh credentials each
LOADER_K_MIN="${LOADER_K_MIN:-10}"
LOADER_DATASET_PREFIX="${LOADER_DATASET_PREFIX:-landing/bank}"
# The data pipeline strips this prefix from every key and takes the first path segment as the table (ingest_bank.table_of):
# without the trailing slash the segment is empty, no table matches and ingest_bank loads nothing. Always end it with one slash.
LOADER_DATASET_PREFIX="${LOADER_DATASET_PREFIX%/}/"
STATE=/srv/data/loader
INBOX_KEY="engine/inbox/READY.json"
STATUS_KEY="engine/loader/status/last.json"
HERE="$(cd "$(dirname "$0")" && pwd)"
CHECK="${LOADER_CHECK_CELLS:-/usr/local/lib/pulso-loader/check_cells_k.py}"

mkdir -p "$STATE" /run/pulso/loader
exec 9>"$STATE/lock"
flock -n 9 || { echo "another loader run is active"; exit 0; }

log() { logger -t pulso-loader -p "user.${2:-info}" "$1"; echo "$1"; }
STEP="start"
status() { # status <state> <detail>; engine/* is writable by the host role; no data, no secrets
  printf '{"state":"%s","run":"%s","at":"%s","detail":"%s"}\n' "$1" "${RUN_KEY:-none}" "$(date -u +%FT%TZ)" "$2" |
    aws s3 cp - "s3://$LOADER_BUCKET/$STATUS_KEY" --region "$LOADER_REGION" --only-show-errors >/dev/null 2>&1 || true
}

# 1. Marker (host credentials; the marker holds names and checksums only).
WORK=""; CREDS=""
cleanup() { rm -f "$CREDS" "$CREDS.new" 2>/dev/null || true; [ -n "$WORK" ] && rm -rf "$WORK" || true; }
trap cleanup EXIT
MARKER="$(mktemp /run/pulso/loader/marker.XXXXXX)"
if ! aws s3 cp "s3://$LOADER_BUCKET/$INBOX_KEY" "$MARKER" --region "$LOADER_REGION" --only-show-errors 2>/dev/null; then
  rm -f "$MARKER"; exit 0 # nothing to load
fi
RUN_KEY="$(sha256sum "$MARKER" | cut -c1-16)"
trap 'rc=$?; [ $rc -ne 0 ] && { status failed "exit $rc at step $STEP"; log "loader run $RUN_KEY failed (exit $rc at step $STEP)" err; }; rm -f "$MARKER"; cleanup' EXIT

# 2. Assume the loader role. Credentials go to a 0600 file under /run (tmpfs), nowhere else. Role chaining caps a session at one hour,
# so the role is assumed again before the pipeline (the cells export can take a good part of the first hour).
CREDS="/run/pulso/loader/$RUN_KEY.env"
assume_loader() {
  aws sts assume-role --role-arn "$LOADER_ROLE_ARN" --external-id "$LOADER_EXTERNAL_ID" --role-session-name "pulso-loader-$RUN_KEY" \
    --duration-seconds 3600 --region "$LOADER_REGION" --query Credentials --output json |
    jq -r '"AWS_ACCESS_KEY_ID=\(.AccessKeyId)\nAWS_SECRET_ACCESS_KEY=\(.SecretAccessKey)\nAWS_SESSION_TOKEN=\(.SessionToken)"' > "$CREDS.new"
  mv -f "$CREDS.new" "$CREDS"
}
assume_loader
# Run a command with the loader credentials, in a subshell: nothing leaks into this shell's environment.
with_loader() { ( set -a; . "$CREDS"; set +a; AWS_DEFAULT_REGION="$LOADER_REGION"; export AWS_DEFAULT_REGION; "$@" ); }

# 3. Idempotency: the same marker content is never loaded twice (survives host replacement: the proof lives in S3).
if with_loader aws s3api head-object --bucket "$LOADER_BUCKET" --key "lake/loader/done/$RUN_KEY.json" >/dev/null 2>&1; then
  log "marker $RUN_KEY already loaded; nothing to do"; rm -f "$MARKER"; exit 0
fi
status running "start"
log "loading marker $RUN_KEY"
WORK="$STATE/work/$RUN_KEY"; rm -rf "$WORK"; mkdir -p "$WORK/e0" "$WORK/cells" "$WORK/scratch/duckdb_tmp" "$WORK/scratch/tmp"
chown -R 10001:10001 "$WORK/scratch" # pipeline user; DuckDB spills here (data volume)

# 4. E0 (landing/e0/ by marker) to a local read-only mount for the pipeline.
E0_PREFIX="$(jq -r '.e0_prefix // empty' "$MARKER")"
STEPS="build,publish"
[ -z "$LOADER_TABLE_BATCHES" ] && STEPS="ingest_bank,$STEPS"
if [ -n "$E0_PREFIX" ]; then
  with_loader aws s3 sync "s3://$LOADER_BUCKET/$E0_PREFIX" "$WORK/e0" --only-show-errors
  chown -R 10001:10001 "$WORK/e0" # umask 077 made the synced files 0600 root; the pipeline container (uid 10001) mounts them read-only
  STEPS="ingest_e0,$STEPS"
fi

# 5. Cells export and k gate: BEFORE any publication. A failing gate stops the run; no data is written or deleted. The producer
# (LOADER_CELLS_CMD, default run-bank-cells.sh) runs with the loader credentials in ITS environment only and reuses cells already
# staged for this run key (a retry after a pipeline failure does not recompute). The staged copy lives under bank_cells/<key>/ and
# is invisible to the engine until bank_cells/latest.json moves (step 7, after the pipeline).
CELLS="$WORK/cells/cells.ndjson"
CELLS_P="s3://$LOADER_BUCKET/lake/gold_analytics/bank_cells"
if [ -n "${LOADER_CELLS_CMD:-}" ]; then
  STEP="cells-export"
  assume_loader # fresh 1 h session: the E0 sync above may have eaten into the first one
  with_loader env CELLS_OUT="$CELLS" RUN_KEY="$RUN_KEY" LOADER_K_MIN="$LOADER_K_MIN" LOADER_DATASET_PREFIX="$LOADER_DATASET_PREFIX" LOADER_BUCKET="$LOADER_BUCKET" bash -c "$LOADER_CELLS_CMD"
  STEP="cells-gate"
  python3 "$CHECK" "$CELLS"
  STEP="cells-stage"
  assume_loader # the export and the gate can take most of an hour
  SUM="$(sha256sum "$CELLS" | cut -d' ' -f1)"; ROWS="$(wc -l < "$CELLS" | tr -d ' ')"
  printf '{"run":"%s","sha256":"%s","rows":%s,"k_min":%s}\n' "$RUN_KEY" "$SUM" "$ROWS" "$LOADER_K_MIN" > "$WORK/cells/MANIFEST.json"
  with_loader aws s3 cp "$CELLS" "$CELLS_P/$RUN_KEY/cells.ndjson" --sse aws:kms --only-show-errors
  with_loader aws s3 cp "$WORK/cells/MANIFEST.json" "$CELLS_P/$RUN_KEY/MANIFEST.json" --sse aws:kms --only-show-errors
else
  log "LOADER_CELLS_CMD is empty: no bank_cells export in this run" warning
fi
STEP="pipeline"

# 6. The data pipeline (one container; limits so the engine keeps running). It reads landing/ through the standard credential chain.
IMAGE="$(grep -E '^PIPELINE_IMAGE=' /srv/stack/.env | cut -d= -f2-)"
[ -n "$IMAGE" ] || { echo "no PIPELINE_IMAGE in /srv/stack/.env" >&2; exit 78; }
ENVF="$(mktemp /run/pulso/loader/pipeline.XXXXXX)"
write_pipeline_env() { # regenerate the whole 0600 env file from the CURRENT $CREDS (called after every assume_loader)
{ cat "$CREDS"
  printf 'DUCKDB_MEMORY_LIMIT=%s\nDUCKDB_TEMP_DIRECTORY=/work/duckdb_tmp\nTMPDIR=/work/tmp\nDBT_THREADS=1\n' "$LOADER_DUCKDB_MEMORY"
  printf 'PSEUDONYM_KEY=%s\nPIPELINE_ROOT=s3://%s/lake\nDATASET_BUCKET=%s\nDATASET_PREFIX=%s\nDATASET_REGION=%s\nAWS_DEFAULT_REGION=%s\nWORK_DIR=/work\n' \
    "$PSEUDONYM_KEY" "$LOADER_BUCKET" "$LOADER_BUCKET" "$LOADER_DATASET_PREFIX" "$LOADER_REGION" "$LOADER_REGION"
  [ -n "$E0_PREFIX" ] && printf 'E0_SOURCE_DIR=/e0\n'; true
} > "$ENVF"
}
trap 'rm -f "$ENVF"; rc=$?; [ $rc -ne 0 ] && { status failed "exit $rc at step $STEP"; log "loader run $RUN_KEY failed (exit $rc at step $STEP)" err; }; rm -f "$MARKER"; cleanup' EXIT
run_pipeline() { # run_pipeline <docker args...>: bounded container, scratch on the data volume (never RAM-backed tmpfs)
  # Every container starts on a fresh session (chained roles are capped at 1 h): re-assume and rewrite the env file first.
  assume_loader
  write_pipeline_env
  docker run --rm --name "pulso-pipeline-$RUN_KEY" --memory "$LOADER_MEMORY" --memory-swap "$LOADER_MEMORY" --cpus "$LOADER_CPUS" --pids-limit 512 \
    --env-file "$ENVF" -v "$WORK/e0:/e0:ro" -v "$WORK/scratch:/work" "$@"
}
# By table (docs/auto-loader.md): each batch is its own short container on fresh credentials, so peak memory is one batch and no
# container outlives one session. ingest_bank is resumable per file (etag manifest): a retry skips what is already ingested.
if [ -n "$LOADER_TABLE_BATCHES" ]; then
  IFS=';' read -ra BATCHES <<< "$LOADER_TABLE_BATCHES"
  for B in "${BATCHES[@]}"; do
    run_pipeline --entrypoint python "$IMAGE" -m pipeline.ingest_bank --tables "$B"
  done
fi
run_pipeline "$IMAGE" --steps "$STEPS"
rm -f "$ENVF"

# 7. Cells to the engine: the pointer moves LAST (the engine host's inputs mirror reads bank_cells/latest.json, verifies the sha256
# and re-runs the k>=10 gate). Only after the pipeline succeeded, so the engine never sees cells of a run whose lake is incomplete.
STEP="cells-publish"
assume_loader # the pipeline may have run for most of an hour
if [ -s "$WORK/cells/MANIFEST.json" ]; then
  with_loader aws s3 cp "$WORK/cells/MANIFEST.json" "$CELLS_P/latest.json" --sse aws:kms --only-show-errors
fi
STEP="done"

# 8. Done marker (idempotency), status, and drop the credentials (trap).
printf '{"run":"%s","at":"%s"}\n' "$RUN_KEY" "$(date -u +%FT%TZ)" > "$WORK/done.json"
assume_loader
with_loader aws s3 cp "$WORK/done.json" "s3://$LOADER_BUCKET/lake/loader/done/$RUN_KEY.json" --sse aws:kms --only-show-errors
status ok "loaded"
rm -f /srv/data/loader/FAILED
log "loader run $RUN_KEY done"
