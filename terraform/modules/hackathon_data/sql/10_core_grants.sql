-- Run as the RDS master, once per Core database:
--   psql ... -d core_runtime -v app_role=core_app    -f 10_core_grants.sql
--   psql ... -d core_eval    -v app_role=core_eval_app -f 10_core_grants.sql
-- `agentcore migrate` connects as core_owner and creates the tables; these default privileges give the runtime role DML
-- and the exporter read-only on everything core_owner creates afterwards. Idempotent.
\set ON_ERROR_STOP on
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO :"app_role", core_exporter_ro;
GRANT CREATE ON SCHEMA public TO core_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE core_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"app_role";
ALTER DEFAULT PRIVILEGES FOR ROLE core_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"app_role";
ALTER DEFAULT PRIVILEGES FOR ROLE core_owner IN SCHEMA public GRANT SELECT ON TABLES TO core_exporter_ro;
-- Tables that already exist (re-run after a migration if the defaults were applied late).
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"app_role";
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"app_role";
GRANT SELECT ON ALL TABLES IN SCHEMA public TO core_exporter_ro;
