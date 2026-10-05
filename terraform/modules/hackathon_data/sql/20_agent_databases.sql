-- Agent services (agent-core serve for support-platform; docs/agent-services.md). Run as the master user, connected to
-- database "postgres". Idempotent. Separate databases from core-runtime's (core_runtime/core_eval): serve runs another
-- agent-core version with its own schema. Passwords come from environment variables (psql 15+ \getenv), never from the
-- command line or from this file.
--   agent_owner  owns both databases; `agentcore migrate` connects as it (AGENT__AGENTCORE_MIGRATE_DSN / _EVAL_DSN)
--   agent_app    DML only, through the default privileges below; `serve` connects as it (AGENT__AGENTCORE_REGISTRY_DSN /
--                _EVAL_DSN). `agentcore migrate --app-role agent_app` narrows the insert-only tables further.
\set ON_ERROR_STOP on
\getenv agent_owner_pw DB_PASSWORD_AGENT_OWNER
\getenv agent_app_pw DB_PASSWORD_AGENT_APP

SELECT format('CREATE ROLE %I LOGIN', r) FROM (VALUES ('agent_owner'), ('agent_app')) v(r)
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = r) \gexec
SELECT format('ALTER ROLE agent_owner PASSWORD %L', :'agent_owner_pw') \gexec
SELECT format('ALTER ROLE agent_app PASSWORD %L', :'agent_app_pw') \gexec

GRANT agent_owner TO CURRENT_USER;

SELECT 'CREATE DATABASE agent_runtime OWNER agent_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'agent_runtime') \gexec
SELECT 'CREATE DATABASE agent_eval OWNER agent_owner' WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'agent_eval') \gexec

REVOKE CONNECT ON DATABASE agent_runtime, agent_eval FROM PUBLIC;
GRANT CONNECT ON DATABASE agent_runtime, agent_eval TO agent_owner, agent_app;

-- Schema privileges, in each database.
\connect agent_runtime
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO agent_app;
GRANT CREATE ON SCHEMA public TO agent_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE agent_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO agent_app;
ALTER DEFAULT PRIVILEGES FOR ROLE agent_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO agent_app;

\connect agent_eval
REVOKE ALL ON SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO agent_app;
GRANT CREATE ON SCHEMA public TO agent_owner;
ALTER DEFAULT PRIVILEGES FOR ROLE agent_owner IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO agent_app;
ALTER DEFAULT PRIVILEGES FOR ROLE agent_owner IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO agent_app;
