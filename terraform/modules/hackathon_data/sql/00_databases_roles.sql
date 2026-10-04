-- Run as the RDS master user, connected to database "postgres". Idempotent. Passwords come from environment variables
-- (psql 15+ \getenv), never from the command line or from this file. See docs/db-bootstrap.md.
\set ON_ERROR_STOP on
\getenv core_owner_pw DB_PASSWORD_CORE_OWNER
\getenv core_app_pw DB_PASSWORD_CORE_APP
\getenv core_eval_app_pw DB_PASSWORD_CORE_EVAL_APP
\getenv core_exporter_ro_pw DB_PASSWORD_CORE_EXPORTER_RO
\getenv pulso_app_pw DB_PASSWORD_PULSO_APP
\getenv pulso_loader_pw DB_PASSWORD_PULSO_LOADER

-- Login roles (create if missing, then always set the password: re-running rotates it).
SELECT format('CREATE ROLE %I LOGIN', r) FROM (VALUES ('core_owner'), ('core_app'), ('core_eval_app'), ('core_exporter_ro')) v(r)
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
SELECT format('ALTER ROLE core_owner PASSWORD %L', :'core_owner_pw') \gexec
SELECT format('ALTER ROLE core_app PASSWORD %L', :'core_app_pw') \gexec
SELECT format('ALTER ROLE core_eval_app PASSWORD %L', :'core_eval_app_pw') \gexec
SELECT format('ALTER ROLE core_exporter_ro PASSWORD %L', :'core_exporter_ro_pw') \gexec
ALTER ROLE core_exporter_ro SET default_transaction_read_only = on;

-- The master must be a member of the owner to create databases owned by it (RDS master is not a superuser).
GRANT core_owner TO CURRENT_USER;

SELECT 'CREATE DATABASE core_runtime OWNER core_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'core_runtime') \gexec
SELECT 'CREATE DATABASE core_eval OWNER core_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'core_eval') \gexec
SELECT 'CREATE DATABASE pulso' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'pulso') \gexec

-- Nobody connects by default (PUBLIC), each role gets exactly its databases.
REVOKE CONNECT ON DATABASE core_runtime, core_eval, pulso FROM PUBLIC;
GRANT CONNECT ON DATABASE core_runtime TO core_owner, core_app, core_exporter_ro;
GRANT CONNECT ON DATABASE core_eval TO core_owner, core_eval_app, core_exporter_ro;

-- Engine logins: the NOLOGIN roles are created by the engine's db/sql/001_roles_schemas.sql (run it on "pulso" next),
-- then sql/30_pulso_logins.sql enables login on pulso_app and pulso_loader.
