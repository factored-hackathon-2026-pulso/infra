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
# Agent services (docs/agent-services.md): only when their passwords are in db.env (agent_services_enabled seeds them).
# On a volume initialised before that, run the same file by hand (docs/agent-services.md, "Database").
if [ -f "$SQL/20_agent_databases.sql" ] && [ -n "${DB_PASSWORD_AGENT_OWNER:-}" ]; then
  for v in DB_PASSWORD_AGENT_OWNER DB_PASSWORD_AGENT_APP; do
    if [ -z "${!v:-}" ] || [ "${!v}" = "CHANGE_ME" ]; then
      echo "init refused: $v (secret key DB__$v) is unset or still CHANGE_ME" >&2
      exit 1
    fi
  done
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -f "$SQL/20_agent_databases.sql"
fi
# Platform and tool-service databases (platform_database_enabled; docs/shared-postgres.md): same rule. The exporter grants
# (sql/26_platform_exporter_grants.sql) are NOT run here: the tables exist only after the platform's first migration.
if [ -f "$SQL/25_platform_databases.sql" ] && [ -n "${DB_PASSWORD_PLATFORM_OWNER:-}" ]; then
  for v in DB_PASSWORD_PLATFORM_OWNER DB_PASSWORD_PLATFORM_APP DB_PASSWORD_PLATFORM_EXPORTER_RO DB_PASSWORD_TOOLS_OWNER DB_PASSWORD_TOOLS_APP; do
    if [ -z "${!v:-}" ] || [ "${!v}" = "CHANGE_ME" ]; then
      echo "init refused: $v (secret key DB__$v) is unset or still CHANGE_ME" >&2
      exit 1
    fi
  done
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -f "$SQL/25_platform_databases.sql"
fi
