#!/bin/sh
# Long-running, idempotent, runs as the Postgres master (env from db.env). Keeps the engine's read-only role on database "platform"
# (platform_exporter_ro) in step with the platform schema: whenever alembic_version and event_log exist and the column layout of
# the tables the exporter reads changed since the last pass, it applies sql/26_platform_exporter_grants.sql (idempotent,
# ON_ERROR_STOP) and prints "exporter grants applied". The platform migrates on ANOTHER host after Postgres is up, so a one-shot
# would run too early; this loop simply waits. It never exits on a missing schema or a transient error (the container restarts
# anyway), prints each state change once, and never prints a password or query output.
set -u
export PGPASSWORD="$POSTGRES_PASSWORD"
PSQL="psql -h ${PGHOST:-postgres} -U pulso_master -d platform -v ON_ERROR_STOP=1 -q"
SQL=/sql/26_platform_exporter_grants.sql
last_fp=""
last_msg=""
say() { [ "$1" = "$last_msg" ] || echo "platform-exporter-grants: $1"; last_msg="$1"; }
while :; do
  if [ ! -f "$SQL" ]; then
    say "$SQL is not in the bundle; nothing to apply"
  else
    fp=$($PSQL -tAc "select case when to_regclass('public.alembic_version') is not null and to_regclass('public.event_log') is not null then (select coalesce(md5(string_agg(table_name || '.' || column_name, ',' order by table_name, column_name)), 'none') from information_schema.columns where table_schema = 'public' and table_name in ('event_log', 'cases')) else '' end" 2>/dev/null) || fp=""
    if [ -z "$fp" ]; then
      say "waiting for the platform migrations (alembic_version and event_log in database platform)"
      last_fp=""
    elif [ "$fp" != "$last_fp" ]; then
      if $PSQL -f "$SQL" >/dev/null 2>&1; then
        last_fp="$fp"
        last_msg=""
        say "exporter grants applied"
        last_msg="applied"
      else
        say "applying the exporter grants failed; will retry"
      fi
    fi
  fi
  sleep "${GRANTS_POLL_SECS:-30}"
done
