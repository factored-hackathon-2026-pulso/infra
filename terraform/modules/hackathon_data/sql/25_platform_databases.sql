-- Platform and tool-service databases on the shared Postgres (platform_database_enabled; docs/shared-postgres.md). Run as the
-- master user, connected to database "postgres". Idempotent. Passwords come from environment variables (psql 15+ \getenv),
-- never from the command line or from this file.
--   platform_owner        owns database "platform"; support-platform's migrations connect as it (SUPPORT__CC_MIGRATE_DATABASE_URL)
--   platform_app          DML only, through the default privileges below; the API connects as it (SUPPORT__CC_DATABASE_URL)
--   platform_exporter_ro  READ-ONLY, only on the tables 26_platform_exporter_grants.sql names (event_log, cases): the engine's
--                         platform-exporter (PULSO__PULSO_PG_PRODUCT_DSN). Never default privileges: a future table with PII
--                         is not readable by the engine until a human adds it there.
--   tools_owner/tools_app database "tools" for tool-service's own state (it uses SQLite today; the roles exist so the move needs no infra change)
\set ON_ERROR_STOP on
\getenv platform_owner_pw DB_PASSWORD_PLATFORM_OWNER
\getenv platform_app_pw DB_PASSWORD_PLATFORM_APP
\getenv platform_exporter_ro_pw DB_PASSWORD_PLATFORM_EXPORTER_RO
\getenv tools_owner_pw DB_PASSWORD_TOOLS_OWNER
\getenv tools_app_pw DB_PASSWORD_TOOLS_APP

SELECT format('CREATE ROLE %I LOGIN', r) FROM (VALUES ('platform_owner'), ('platform_app'), ('platform_exporter_ro'), ('tools_owner'), ('tools_app')) v(r)
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
SELECT format('ALTER ROLE platform_owner PASSWORD %L', :'platform_owner_pw') \gexec
SELECT format('ALTER ROLE platform_app PASSWORD %L', :'platform_app_pw') \gexec
SELECT format('ALTER ROLE platform_exporter_ro PASSWORD %L', :'platform_exporter_ro_pw') \gexec
SELECT format('ALTER ROLE tools_owner PASSWORD %L', :'tools_owner_pw') \gexec
SELECT format('ALTER ROLE tools_app PASSWORD %L', :'tools_app_pw') \gexec
ALTER ROLE platform_exporter_ro SET default_transaction_read_only = on;

-- The master must be a member of an owner to create a database owned by it.
GRANT platform_owner TO CURRENT_USER;
GRANT tools_owner TO CURRENT_USER;

SELECT 'CREATE DATABASE platform OWNER platform_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'platform') \gexec
SELECT 'CREATE DATABASE tools OWNER tools_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'tools') \gexec

REVOKE CONNECT ON DATABASE platform, tools FROM PUBLIC;
GRANT CONNECT ON DATABASE platform TO platform_owner, platform_app, platform_exporter_ro;
GRANT CONNECT ON DATABASE tools TO tools_owner, tools_app;

\connect platform
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO platform_app, platform_exporter_ro;
GRANT CREATE ON SCHEMA public TO platform_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE platform_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO platform_app;
ALTER DEFAULT PRIVILEGES FOR ROLE platform_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO platform_app;

\connect tools
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO tools_app;
GRANT CREATE ON SCHEMA public TO tools_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE tools_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO tools_app;
ALTER DEFAULT PRIVILEGES FOR ROLE tools_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO tools_app;
