#!/bin/bash
# Producer of the bank cells for the automatic loader (the default of LOADER_CELLS_CMD; docs/auto-loader.md, "Cells"). Run by
# pulso-loader.sh under `with_loader` (the loader role credentials are in THIS process environment only) and as root on the engine host.
#
#   landing/bank/<table>/**/*.csv + customers.csv + marketing_campaigns.csv   (the SAME layout bank_cells.py was validated on)
#     -> aws s3 sync with the loader credentials, to a scratch directory on the data volume
#     -> bank_cells.py inside the ENGINE image, in a container with NO network, NO credentials, a read-only root and a memory cap
#     -> $CELLS_OUT (aggregates only: metric, dims, half, period, numerator, denominator; k >= 10)
# The caller (pulso-loader.sh) then runs check_cells_k.py on $CELLS_OUT: this script never publishes anything.
#
# Why not the pipeline's silver/gold: bank_cells.py reads the raw CSV partitions by the dataset's own table and column names
# (call_center_interactions, complaints, ...), keeps rows the pipeline quarantines out of silver, and computes the A/B split from the
# real customer_id (silver and gold pseudonymise it, which would change every half). Reading landing/ keeps the validated numbers.
#
# Idempotent per run key: cells already staged at bank_cells/<RUN_KEY>/ (by an earlier attempt of the same marker) whose sha256 matches
# their manifest are reused, so a retry after a pipeline failure does not repeat the sync and the 8 minute aggregation.
# Prints counts only (the aggregator's summary), never rows. Exit: 78 refused configuration, 66 missing input, 75 not enough disk,
# 124 timeout, else the container's exit code.
set -euo pipefail
umask 077
: "${CELLS_OUT:?}" "${RUN_KEY:?}" "${LOADER_BUCKET:?}" "${LOADER_DATASET_PREFIX:?}"
K="${LOADER_K_MIN:-10}"
case "$K" in ''|*[!0-9]*) echo "run-bank-cells refused: LOADER_K_MIN is not a number" >&2; exit 78 ;; esac
[ "$K" -ge 10 ] || { echo "run-bank-cells refused: LOADER_K_MIN below 10" >&2; exit 78; }
MEM="${LOADER_CELLS_MEMORY:-1g}"          # docker --memory; the aggregator held a few hundred MB on the laptop (UNMEASURED on EC2)
CPUS="${LOADER_CELLS_CPUS:-1.0}"
TIMEOUT_S="${LOADER_CELLS_TIMEOUT_S:-3600}"  # about 8 minutes on a laptop; the loader session is re-assumed after this step
ENV_FILE="${LOADER_STACK_ENV:-/srv/stack/.env}"
PREFIX="${LOADER_DATASET_PREFIX%/}"        # the pipeline wants this prefix WITH a trailing slash; here it is normalised
CELLS_P="s3://$LOADER_BUCKET/lake/gold_analytics/bank_cells"
AGGREGATOR="${LOADER_CELLS_AGGREGATOR:-/opt/pulso/aggregate/bank_cells.py}"
# Contract with the engine's scripts/aggregate/bank_cells.py (ALLOWED_TABLES and REF_COLUMNS; pinned by a test in each repo).
TABLES="call_center_interactions complaints satisfaction_surveys digital_events campaign_sends transactions"
REFS="customers.csv marketing_campaigns.csv"

log() { logger -t pulso-loader-cells -p "user.${2:-info}" "$1" 2>/dev/null || true; echo "$1"; }
DIR="$(dirname "$CELLS_OUT")"
IN="$DIR/in"; OUT="$DIR/out"; NAME="pulso-cells-$RUN_KEY"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; rm -rf "$IN" "$OUT" "$DIR/.staged.json"; }
trap cleanup EXIT
mkdir -p "$DIR"

# 1. Reuse what this run key already staged (sha256 must match its manifest).
if aws s3 cp "$CELLS_P/$RUN_KEY/MANIFEST.json" "$DIR/.staged.json" --only-show-errors 2>/dev/null; then
  WANT="$(grep -o '"sha256": *"[0-9a-f]*"' "$DIR/.staged.json" | head -n1 | grep -o '[0-9a-f]\{64\}' || true)"  # the manifest is written by pulso-loader.sh
  if [ -n "$WANT" ] && aws s3 cp "$CELLS_P/$RUN_KEY/cells.ndjson" "$CELLS_OUT" --only-show-errors 2>/dev/null \
     && [ "$(sha256sum "$CELLS_OUT" | cut -d' ' -f1)" = "$WANT" ]; then
    log "bank cells of run $RUN_KEY are already staged (sha256 verified); not recomputed"
    exit 0
  fi
  rm -f "$CELLS_OUT"
fi

IMAGE="$(grep -E '^PULSO_IMAGE=' "$ENV_FILE" | cut -d= -f2-)"
[ -n "$IMAGE" ] || { echo "no PULSO_IMAGE in $ENV_FILE" >&2; exit 78; }

# 2. Inputs: only the six tables and the two reference files; everything must be there (a silently absent table would drop its
# metrics). Disk first: the CSV must fit on the data volume with 20% headroom.
NEED=0
for t in $TABLES; do
  B="$(aws s3 ls "s3://$LOADER_BUCKET/$PREFIX/$t/" --recursive --summarize 2>/dev/null | awk '/Total Size:/ {print $3}' || true)"
  [ -n "$B" ] && [ "$B" -gt 0 ] || { echo "missing input: s3://$LOADER_BUCKET/$PREFIX/$t/ has no objects" >&2; exit 66; }
  NEED=$((NEED + B))
done
AVAIL="$(df -PB1 "$DIR" | awk 'NR==2 {print $4}')"
[ "$AVAIL" -gt $((NEED / 5 * 6)) ] || { echo "not enough disk for the cells inputs: need $((NEED / 1048576)) MiB plus 20%, have $((AVAIL / 1048576)) MiB" >&2; exit 75; }
mkdir -p "$IN" "$OUT"
for t in $TABLES; do
  aws s3 sync "s3://$LOADER_BUCKET/$PREFIX/$t/" "$IN/$t/" --exclude "*" --include "*.csv" --only-show-errors
done
for r in $REFS; do
  aws s3 cp "s3://$LOADER_BUCKET/$PREFIX/$r" "$IN/$r" --only-show-errors || { echo "missing input: $PREFIX/$r" >&2; exit 66; }
done
chmod -R a+rX "$IN"            # the container runs as uid 10001
chown 10001:10001 "$OUT"

# 3. The aggregator, in the engine image: no network, no credentials in its environment, read-only root, bounded memory/cpu/time.
log "running bank_cells.py (k=$K, memory $MEM) over $((NEED / 1048576)) MiB of landing CSV"
timeout "$TIMEOUT_S" docker run --rm --name "$NAME" --network none --read-only --tmpfs /tmp:rw,noexec,nosuid,size=64m \
  --cap-drop ALL --security-opt no-new-privileges --user 10001:10001 \
  --memory "$MEM" --memory-swap "$MEM" --cpus "$CPUS" --pids-limit 64 -e PYTHONDONTWRITEBYTECODE=1 \
  -v "$IN:/in:ro" -v "$OUT:/out" --entrypoint python3 "$IMAGE" \
  "$AGGREGATOR" --data-root /in --out /out/cells.ndjson --k "$K"
[ -s "$OUT/cells.ndjson" ] || { echo "bank_cells.py wrote no cells" >&2; exit 65; }
mv -f "$OUT/cells.ndjson" "$CELLS_OUT"
log "bank cells written ($(wc -l < "$CELLS_OUT" | tr -d ' ') rows); the gate runs next"
