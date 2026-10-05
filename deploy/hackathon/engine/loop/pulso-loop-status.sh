#!/bin/bash
# ExecStopPost of pulso-loop.service: turns the exit status of `pulso loop` into a status file, a log line and (for failures) a marker.
# Exit codes (improvement-engine docs/dev/ENGINE_PROD.md):
#   0   finished, every finding closed                 success
#   75  another run holds loop.lock                    success (nothing was done)
#   143 SIGTERM (stop/shutdown)                        success (clean stop); the lock the run could not release is removed
#   3   finished with an infrastructure failure        FAILURE, ALERT (journal priority err + marker); a re-run resumes the records
#   2   refused configuration                          failure, not retried (RestartPreventExitStatus=2): fix the named variable
#   1 and anything else: could not run (inputs missing, work dir, model setup), the timer / Restart retries
# Prints no environment and no secret. systemd provides $EXIT_STATUS, $EXIT_CODE and $SERVICE_RESULT.
set -uo pipefail
STATE="${LOOP_STATE_DIR:-/srv/data/loop}"
WORK="${LOOP_WORK_DIR:-/srv/data/pulso/work}"
mkdir -p "$STATE" 2>/dev/null || true
code="${EXIT_STATUS:-unknown}"
case "$code" in TERM) code=143 ;; esac
log() { logger -t pulso-loop -p "user.$2" "$1" 2>/dev/null || true; echo "$1"; }

case "$code" in
  0)   state=ok;            sev=info;    rm -f "$STATE/FAILED" ;;
  75)  state=locked;        sev=info ;;
  143) state=stopped;       sev=notice
       # Not trapped by the engine: a stop leaves loop.lock behind. Safe to remove only when no loop container is left.
       if [ -z "$(docker ps -q --filter label=com.docker.compose.service=pulso-loop 2>/dev/null)" ]; then rm -f "$WORK/loop.lock"; fi ;;
  3)   state=failed_infra;  sev=err ;;
  2)   state=refused;       sev=err ;;
  *)   state=failed;        sev=err ;;
esac
printf '{"state":"%s","exit":"%s","result":"%s","at":"%s"}\n' "$state" "$code" "${SERVICE_RESULT:-unknown}" "$(date -u +%FT%TZ)" > "$STATE/last.json"
if [ "$sev" = err ]; then
  date -u +%FT%TZ > "$STATE/FAILED"
  log "pulso loop ended '$state' (exit $code); see journalctl -u pulso-loop and $STATE/last.json" err
else
  log "pulso loop ended '$state' (exit $code)" "$sev"
fi
# Best effort: the same one-line status in S3 for the operator (engine/* is writable by the host role); no data, no secrets.
if [ "${LOOP_SKIP_S3:-0}" != 1 ]; then
  BUCKET="$(grep -E '^BUCKET_NAME=' /srv/stack/.env 2>/dev/null | cut -d= -f2-)"
  if [ -n "$BUCKET" ] && command -v aws >/dev/null 2>&1; then
    aws s3 cp "$STATE/last.json" "s3://$BUCKET/engine/loop/status/last.json" --only-show-errors >/dev/null 2>&1 || true
  fi
fi
exit 0
