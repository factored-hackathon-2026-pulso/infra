#!/bin/bash
# First start of an EMPTY data volume only (docker-entrypoint-initdb.d). Creates the databases, login roles and grants
# from the repository SQL (the same files docs/db-bootstrap.md uses for RDS). Passwords come from db.env (secret keys
# DB__DB_PASSWORD_<ROLE>); a CHANGE_ME placeholder refuses the init so the volume is never seeded with it.
# The engine's own migrations (db/sql/001..090 on database "pulso", then sql/30_pulso_logins.sql) run afterwards.
set -euo pipefail
for v in DB_PASSWORD_CORE_OWNER DB_PASSWORD_CORE_APP DB_PASSWORD_CORE_EVAL_APP DB_PASSWORD_CORE_EXPORTER_RO DB_PASSWORD_PULSO_APP DB_PASSWORD_PULSO_LOADER; do
  if [ -z "${!v:-}" ] || [ "${!v}" = "CHANGE_ME" ]; then
    echo "init refused: $v (secret key DB__$v) is unset or still CHANGE_ME" >&2
    exit 1
  fi
done
SQL=/docker-entrypoint-initdb.d/sql
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -f "$SQL/00_databases_roles.sql"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d core_runtime -v app_role=core_app -f "$SQL/10_core_grants.sql"
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d core_eval -v app_role=core_eval_app -f "$SQL/10_core_grants.sql"
