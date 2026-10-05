#!/bin/bash
# Mirror of the engine's loop inputs on the engine host: /srv/data/inputs (mounted read-only into the loop job). Run by
# pulso-loop.service as ExecStartPre, with the HOST role (engine/* read-write, lake/gold_analytics read). Never prints a secret and
# never creates the cells: it only COPIES what the auto-loader already published (docs/auto-loader.md) and re-checks it.
#
#   1. s3://<bucket>/engine/inputs/  ->  staging           (operator-provided inputs, for example E0 or a synthetic cells file)
#   2. if the loader published lake/gold_analytics/bank_cells/latest.json: its run's cells.ndjson replaces staging/cells.ndjson
#      after the sha256 of its manifest matches and check_cells_k.py (k>=10, allowed keys only) passes AGAIN (the loader gated it
#      once; this is the second, independent check on the engine host)
#   3. staging must hold a non-empty cells.ndjson, then it is swapped in (mv of directories)
# A failed sync keeps the previous mirror (warning) and exits 0 when that mirror still has cells.ndjson; with no usable mirror it
# exits 1, so the unit fails visibly instead of the loop running on nothing (`pulso loop` would exit 1 anyway: inputs not synced).
set -euo pipefail
umask 022
BUCKET="${INPUTS_BUCKET:-}"
[ -n "$BUCKET" ] || BUCKET="$(grep -E '^BUCKET_NAME=' /srv/stack/.env | cut -d= -f2-)"
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
if [ -z "$REGION" ]; then
  TOKEN="$(curl -fsS -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token)"
  REGION="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/placement/region)"
fi
INPUTS_PREFIX="${INPUTS_PREFIX:-engine/inputs}"
CELLS_PREFIX="${CELLS_PREFIX:-lake/gold_analytics/bank_cells}"
CELLS_FILE="${CELLS_FILE:-cells.ndjson}"
DEST="${INPUTS_DIR:-/srv/data/inputs}"
CHECK="${LOADER_CHECK_CELLS:-/usr/local/lib/pulso-loader/check_cells_k.py}"
: "${BUCKET:?no BUCKET_NAME in /srv/stack/.env}"

log() { logger -t pulso-inputs-sync -p "user.${2:-info}" "$1" 2>/dev/null || true; echo "$1"; }
keep_previous() {
  if [ -s "$DEST/$CELLS_FILE" ]; then log "$1; keeping the previous mirror" warning; exit 0; fi
  log "$1; there is no previous mirror either" err; exit 1
}

mkdir -p "$(dirname "$DEST")"
STAGE="$(mktemp -d "${DEST}.stage.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

aws s3 sync "s3://$BUCKET/$INPUTS_PREFIX/" "$STAGE/" --region "$REGION" --only-show-errors || keep_previous "sync of $INPUTS_PREFIX failed"

if aws s3 cp "s3://$BUCKET/$CELLS_PREFIX/latest.json" "$STAGE/.manifest.json" --region "$REGION" --only-show-errors 2>/dev/null; then
  RUN="$(jq -r '.run // empty' "$STAGE/.manifest.json")"
  WANT="$(jq -r '.sha256 // empty' "$STAGE/.manifest.json")"
  case "$RUN" in
    ""|*[!A-Za-z0-9._-]*) keep_previous "bank_cells/latest.json has no valid run" ;;
  esac
  aws s3 cp "s3://$BUCKET/$CELLS_PREFIX/$RUN/cells.ndjson" "$STAGE/.cells.new" --region "$REGION" --only-show-errors || keep_previous "could not fetch bank cells of run $RUN"
  GOT="$(sha256sum "$STAGE/.cells.new" | cut -d' ' -f1)"
  if [ -z "$WANT" ] || [ "$GOT" != "$WANT" ]; then keep_previous "bank cells of run $RUN do not match their manifest sha256"; fi
  if [ -f "$CHECK" ]; then python3 "$CHECK" "$STAGE/.cells.new" >/dev/null || keep_previous "bank cells of run $RUN fail the k>=10 gate"; fi
  mv -f "$STAGE/.cells.new" "$STAGE/$CELLS_FILE"
  log "bank cells of run $RUN (sha256 verified) are the loop input"
fi
rm -f "$STAGE/.manifest.json"

[ -s "$STAGE/$CELLS_FILE" ] || keep_previous "no $CELLS_FILE in s3://$BUCKET/$INPUTS_PREFIX/ and no loader cells"
chmod -R a+rX "$STAGE"
rm -rf "$DEST.old"
if [ -e "$DEST" ]; then mv "$DEST" "$DEST.old"; fi
mv "$STAGE" "$DEST"
rm -rf "$DEST.old"
trap - EXIT
log "inputs mirror updated: $(find "$DEST" -type f | wc -l) files"
