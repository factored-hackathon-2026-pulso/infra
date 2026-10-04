#!/bin/bash
# Host-side deploy of new image digests, run by the SSM Command document pulso-deploy-<workload> (no instance
# replacement, no SSH). The digests are already in SSM Parameter Store (<ssm_prefix>/<workload>/images/<key>).
#
#   1. render the env (pulso-stack-prepare reads the digests from SSM and rewrites .env and the service env files)
#   2. docker compose pull   (new digests; running containers are not touched yet)
#   3. docker compose up -d  (recreates only the services whose image changed)
#   4. wait until every container is healthy (or exited 0 for one-shot jobs), twice in a row, within the timeout
#   5. on any failure: put the previous digests back from the local state file, bring the stack up on them,
#      print DEPLOY_RESULT=rolled_back and exit non-zero
#
# Output ends with exactly one DEPLOY_RESULT=ok|rolled_back|failed line. No secret value is read or printed here
# (secrets are rendered by pulso-stack-prepare into tmpfs files, never into .env).
set -uo pipefail

STACK_DIR="${STACK_DIR:-/srv/stack}"
PREPARE="${PULSO_PREPARE:-/usr/local/bin/pulso-stack-prepare}"
TIMEOUT="${DEPLOY_HEALTH_TIMEOUT:-300}"
INTERVAL="${DEPLOY_HEALTH_INTERVAL:-5}"

cd "$STACK_DIR" || { echo "cannot enter $STACK_DIR"; echo "DEPLOY_RESULT=failed"; exit 1; }
STATE_DIR="$STACK_DIR/.deploy-state"
ENV_FILE="$STACK_DIR/.env"
mkdir -p "$STATE_DIR"

compose() { docker compose -p pulso "$@"; }
image_lines() { { grep -E '^[A-Z0-9_]+_IMAGE=' "$ENV_FILE" || true; } | sort; }

restore_images() {
  local tmp="$ENV_FILE.restore"
  { grep -v -E '^[A-Z0-9_]+_IMAGE=' "$ENV_FILE" || true; cat "$STATE_DIR/before-images.env"; } > "$tmp" && mv "$tmp" "$ENV_FILE"
}

wait_healthy() {
  local deadline=$(( $(date +%s) + TIMEOUT )) stable=0 ids id status health code pending bad
  while :; do
    pending=0
    bad=""
    ids=$(compose ps -a -q) || { echo "cannot list containers"; return 1; }
    [ -n "$ids" ] || pending=1
    for id in $ids; do
      read -r status health code < <(docker inspect --format '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}} {{.State.ExitCode}}' "$id")
      if [ "$health" = "unhealthy" ]; then bad="$id is unhealthy"
      elif [ "$status" = "restarting" ]; then bad="$id is restarting"
      elif [ "$status" = "dead" ]; then bad="$id is dead"
      elif [ "$status" = "exited" ]; then
        [ "${code:-1}" = "0" ] || bad="$id exited with code $code"
      elif [ "$health" = "starting" ] || [ "$status" = "created" ]; then pending=1
      fi
    done
    if [ -n "$bad" ]; then echo "unhealthy: $bad"; return 1; fi
    if [ "$pending" = "0" ]; then
      stable=$((stable + 1))
      [ "$stable" -ge 2 ] && return 0
    else
      stable=0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then echo "timeout after ${TIMEOUT}s waiting for healthy containers"; return 1; fi
    sleep "$INTERVAL"
  done
}

image_lines > "$STATE_DIR/before-images.env"

if ! "$PREPARE"; then
  echo "pulso-stack-prepare failed; nothing was changed"
  echo "DEPLOY_RESULT=failed"
  exit 1
fi
image_lines > "$STATE_DIR/after-images.env"

if ! compose pull --quiet; then
  echo "docker compose pull failed; running containers were not touched"
  restore_images
  echo "DEPLOY_RESULT=failed"
  exit 1
fi

rollback() {
  echo "$1; restoring the previous digests"
  restore_images
  if compose up -d --remove-orphans && wait_healthy; then
    echo "DEPLOY_RESULT=rolled_back"
  else
    echo "rollback did not become healthy either; inspect with: docker compose -p pulso ps / logs"
    echo "DEPLOY_RESULT=failed"
  fi
  exit 1
}

compose up -d --remove-orphans || rollback "docker compose up failed"
wait_healthy || rollback "new digests did not become healthy"

if ! cmp -s "$STATE_DIR/before-images.env" "$STATE_DIR/after-images.env"; then
  cp "$STATE_DIR/before-images.env" "$STATE_DIR/previous-images.env"
fi
cp "$STATE_DIR/after-images.env" "$STATE_DIR/current-images.env"
while read -r line; do echo "DEPLOYED $line"; done < "$STATE_DIR/after-images.env"
compose ps
echo "DEPLOY_RESULT=ok"
