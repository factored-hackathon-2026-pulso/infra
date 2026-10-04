#!/bin/bash
# buildbox-runner.sh: executed ON the buildbox by SSM (AWS-RunShellScript). Shipped through s3://<bucket>/runner/.
#   buildbox-runner.sh --bucket B --lane L --id I [--jobs N] [--timeout MIN] --cmd-b64 BASE64
#   buildbox-runner.sh gc --hours H
# Contract: extract jobs/<lane>/<id>.tar.gz into /work/<lane>/<id>, export CARGO_TARGET_DIR=/work/target/<lane>,
# take one of at most MAX_JOBS=3 slots, run the command, write combined.log, exit-code and result.json to out/<lane>/<id>/.
set -uo pipefail
MAX_JOBS=3
WORK=/work
# shellcheck disable=SC1091
[ -r /etc/profile.d/buildbox.sh ] && . /etc/profile.d/buildbox.sh

MODE=run
if [ "${1:-}" = "gc" ]; then MODE=gc; shift; fi

BUCKET=""; LANE=""; ID=""; JOBS=2; TIMEOUT_MIN=60; CMD_B64=""; HOURS=24
while [ $# -gt 0 ]; do
  case "$1" in
    --bucket) BUCKET="$2"; shift 2 ;;
    --lane) LANE="$2"; shift 2 ;;
    --id) ID="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --timeout) TIMEOUT_MIN="$2"; shift 2 ;;
    --cmd-b64) CMD_B64="$2"; shift 2 ;;
    --hours) HOURS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [ "$MODE" = "gc" ]; then
  mkdir -p "$WORK/.jobs"
  # work dirs are /work/<lane>/<job>; never touch the cargo/target caches or dot dirs
  find "$WORK" -mindepth 2 -maxdepth 2 -type d -not -path "$WORK/target/*" -not -path "$WORK/cargo/*" \
    -not -path "$WORK/.*" -mmin "+$((HOURS * 60))" -print | while read -r d; do
    lane=$(basename "$(dirname "$d")"); job=$(basename "$d")
    if [ -e "$WORK/.jobs/${lane}__${job}" ]; then continue; fi
    echo "gc: removing $d"; rm -rf "$d"
  done
  df -h "$WORK" | tail -n1
  exit 0
fi

[[ "$LANE" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || { echo "bad lane" >&2; exit 64; }
[[ "$ID" =~ ^[A-Za-z0-9-]+$ ]] || { echo "bad id" >&2; exit 64; }
[ -n "$BUCKET" ] && [ -n "$CMD_B64" ] || { echo "missing --bucket or --cmd-b64" >&2; exit 64; }
CMD=$(printf '%s' "$CMD_B64" | base64 -d)

mkdir -p "$WORK/.jobs" "$WORK/.locks" "$WORK/.tmp" "$WORK/target/$LANE" "$WORK/$LANE"
MARKER="$WORK/.jobs/${LANE}__${ID}"
JOBDIR="$WORK/$LANE/$ID"
OUT="$WORK/.tmp/out-${LANE}-${ID}"
mkdir -p "$OUT"
touch "$MARKER"            # keeps the idle auto-stop away, also while waiting for a slot
echo "running" | aws s3 cp - "s3://$BUCKET/state/running/$LANE/$ID" --quiet || true
cleanup() { rm -f "$MARKER"; aws s3 rm "s3://$BUCKET/state/running/$LANE/$ID" --quiet || true; }
trap cleanup EXIT

# --- per-box semaphore: at most MAX_JOBS concurrent jobs ---
acquired=0
deadline=$(( $(date +%s) + TIMEOUT_MIN * 60 ))
while [ "$acquired" -eq 0 ]; do
  for i in $(seq 1 "$MAX_JOBS"); do
    exec 9>"$WORK/.locks/slot$i"
    if flock -n 9; then acquired=1; break; fi
    exec 9>&-
  done
  if [ "$acquired" -eq 0 ]; then
    [ "$(date +%s)" -lt "$deadline" ] || { echo "timed out waiting for a free slot (max $MAX_JOBS jobs)" >&2; exit 75; }
    sleep 5
  fi
done

started=$(date -u +%FT%TZ); t0=$(date +%s)
{
  echo "== buildbox job $LANE/$ID started $started (slot acquired, jobs=$JOBS, timeout=${TIMEOUT_MIN}m)"
  rm -rf "$JOBDIR"; mkdir -p "$JOBDIR"
  aws s3 cp "s3://$BUCKET/jobs/$LANE/$ID.tar.gz" "$OUT/src.tar.gz" --quiet \
    && tar -xzf "$OUT/src.tar.gz" -C "$JOBDIR" && rm -f "$OUT/src.tar.gz"
} > "$OUT/combined.log" 2>&1
rc=$?

if [ "$rc" -eq 0 ]; then
  cd "$JOBDIR" || exit 70
  # a linked git worktree ships a .git pointer file that is useless here: give the box a fresh repo
  if [ -f .git ]; then
    rm -f .git
    git init -q . && git add -A >/dev/null 2>&1 \
      && git -c user.name=buildbox -c user.email=buildbox@localhost commit -qm snapshot >/dev/null 2>&1
  fi
  export CARGO_TARGET_DIR="/work/target/$LANE"
  export CARGO_BUILD_JOBS="$JOBS"
  export BUILDBOX_JOB_DIR="$JOBDIR" BUILDBOX_LANE="$LANE" BUILDBOX_ID="$ID"
  # the toolchain is read from the job (rust-toolchain.toml / rust-toolchain) at run time
  if [ -f rust-toolchain.toml ] || [ -f rust-toolchain ]; then
    echo "== rustup: installing the toolchain pinned by rust-toolchain" >> "$OUT/combined.log"
    rustup toolchain install >> "$OUT/combined.log" 2>&1 || true
  fi
  { echo "== running: $CMD"; timeout --signal=TERM --kill-after=30 "${TIMEOUT_MIN}m" bash -c "$CMD"; } 2>&1 | tee -a "$OUT/combined.log"
  rc=${PIPESTATUS[0]}
fi

finished=$(date -u +%FT%TZ); dur=$(( $(date +%s) - t0 ))
echo "$rc" > "$OUT/exit-code"
jq -n --arg lane "$LANE" --arg id "$ID" --argjson rc "$rc" --arg s "$started" --arg f "$finished" --argjson d "$dur" --arg cmd "$CMD" \
  '{lane:$lane,id:$id,exit_code:$rc,started:$s,finished:$f,duration_s:$d,command:$cmd}' > "$OUT/result.json"
for f in combined.log exit-code result.json; do
  aws s3 cp "$OUT/$f" "s3://$BUCKET/out/$LANE/$ID/$f" --quiet || true
done
rm -rf "$OUT"
exit "$rc"
