-- Post-migration grants of the platform database. Run as the master user, connected to database "platform", AFTER
-- support-platform's migrations (docs/shared-postgres.md; support-platform docs/platform/deploy/database.md sections 3.2 and 3.3).
-- Idempotent: re-run it after every migration that adds a table or a column the engine must read.
--  1. platform_app: event_log is append-only (read and append), alembic_version is the migration job's business.
--  2. platform_exporter_ro: COLUMN-level SELECT on an explicit allow-list (event_log, cases incl. case_type); no free text,
--     no mutable state (cases.status, closed_at, close_reason, previews, notes stay unreadable).
\set ON_ERROR_STOP on
DO $$
BEGIN
  IF to_regclass('public.event_log') IS NOT NULL THEN
    REVOKE UPDATE, DELETE, TRUNCATE ON public.event_log FROM platform_app;
  END IF;
  IF to_regclass('public.alembic_version') IS NOT NULL THEN
    REVOKE INSERT, UPDATE, DELETE ON public.alembic_version FROM platform_app;
  END IF;
END $$;

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM platform_exporter_ro;
DO $$
DECLARE r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('event_log', 'sequence, event_id, event_type, entity, entity_id, case_id, actor_role, actor_id, event_time, ingested_at, payload'),
    ('cases', 'id, customer_id, channel, language, priority, case_type, opened_at, sla_due_at, previous_case_id, rating_score, rated_at')
  ) AS v(tbl, cols) LOOP
    IF to_regclass(format('public.%I', r.tbl)) IS NOT NULL THEN
      EXECUTE format('GRANT SELECT (%s) ON public.%I TO platform_exporter_ro', r.cols, r.tbl);
    ELSE
      RAISE NOTICE 'table % does not exist yet: run the platform migrations, then this file again', r.tbl;
    END IF;
  END LOOP;
END $$;
