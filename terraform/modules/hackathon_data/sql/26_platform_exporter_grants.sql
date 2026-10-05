-- Read-only access of the engine's platform-exporter to the platform database. Run as the master user, connected to
-- database "platform", AFTER support-platform's migrations created the tables (docs/shared-postgres.md); idempotent, so re-run it
-- after every migration that adds a column. The allow-list is explicit: only the append-only event log and the case table
-- (cases.case_type). Everything else (staff, sessions, credentials, messages, notifications) stays unreadable.
\set ON_ERROR_STOP on
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM platform_exporter_ro;
DO $$
DECLARE t text;
BEGIN
  FOREACH t IN ARRAY ARRAY['event_log', 'cases'] LOOP
    IF to_regclass(format('public.%I', t)) IS NOT NULL THEN
      EXECUTE format('GRANT SELECT ON public.%I TO platform_exporter_ro', t);
    ELSE
      RAISE NOTICE 'table % does not exist yet: run the platform migrations, then this file again', t;
    END IF;
  END LOOP;
END $$;
