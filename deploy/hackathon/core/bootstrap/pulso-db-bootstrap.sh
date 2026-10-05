#!/bin/sh
# One-shot, idempotent, runs as the Postgres master (env from db.env). Enables LOGIN on the engine roles with
# sql/30_pulso_logins.sql AFTER the engine's migrations created them (its first start; the engine DSN is the master role until
# this prints "logins enabled", then the secret PULSO__PULSO_DATABASE_URL is switched to pulso_app, see docs/run-and-health.md).
# Prints no password and no query output. Exit 0 when the roles do not exist yet: nothing to do until the engine has started.
set -eu
export PGPASSWORD="$POSTGRES_PASSWORD"
PSQL="psql -h ${PGHOST:-postgres} -U pulso_master -d pulso -v ON_ERROR_STOP=1 -q"
deadline=$(( $(date +%s) + ${BOOTSTRAP_WAIT_SECS:-120} ))
while :; do
  n=$($PSQL -tAc "select count(*) from pg_roles where rolname in ('pulso_app','pulso_loader','pulso_raw_ro','pulso_augmented_ro','pulso_product_ro')" 2>/dev/null || echo 0)
  [ "$n" = "5" ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "pulso-db-bootstrap: engine roles not created yet (found $n of 5); start the engine, then redeploy core to rerun"
    exit 0
  fi
  sleep 5
done
$PSQL -f /sql/30_pulso_logins.sql >/dev/null
echo "pulso-db-bootstrap: logins enabled"
