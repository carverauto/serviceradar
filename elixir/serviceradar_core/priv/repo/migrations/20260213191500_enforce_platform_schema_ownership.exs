defmodule ServiceRadar.Repo.Migrations.EnforcePlatformSchemaOwnership do
  @moduledoc """
  Enforces canonical ownership for the platform schema and its objects.

  This is intentionally idempotent and safe to run repeatedly across
  Helm and Docker Compose deployments.
  """

  use Ecto.Migration

  def up do
    execute("""
    DO $$
    DECLARE
      rel RECORD;
      view_rec RECORD;
      matview_rec RECORD;
      seq_rec RECORD;
      routine_rec RECORD;
    BEGIN
      IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'serviceradar') THEN
        RAISE NOTICE 'Role serviceradar does not exist; skipping platform ownership enforcement';
        RETURN;
      END IF;

      EXECUTE 'CREATE SCHEMA IF NOT EXISTS platform AUTHORIZATION serviceradar';
      EXECUTE 'ALTER SCHEMA platform OWNER TO serviceradar';

      FOR rel IN
        SELECT c.relname, c.relkind
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'platform'
          AND c.relkind IN ('r', 'p', 'f')
      LOOP
        EXECUTE format('ALTER TABLE platform.%I OWNER TO serviceradar', rel.relname);
      END LOOP;

      FOR seq_rec IN
        SELECT sequencename
        FROM pg_sequences
        WHERE schemaname = 'platform'
      LOOP
        EXECUTE format('ALTER SEQUENCE platform.%I OWNER TO serviceradar', seq_rec.sequencename);
      END LOOP;

      FOR view_rec IN
        SELECT viewname
        FROM pg_views
        WHERE schemaname = 'platform'
      LOOP
        BEGIN
          EXECUTE format('ALTER VIEW platform.%I OWNER TO serviceradar', view_rec.viewname);
        EXCEPTION
          WHEN OTHERS THEN
            EXECUTE format(
              'ALTER MATERIALIZED VIEW platform.%I OWNER TO serviceradar',
              view_rec.viewname
            );
        END;
      END LOOP;

      FOR matview_rec IN
        SELECT matviewname
        FROM pg_matviews
        WHERE schemaname = 'platform'
      LOOP
        EXECUTE format(
          'ALTER MATERIALIZED VIEW platform.%I OWNER TO serviceradar',
          matview_rec.matviewname
        );
      END LOOP;

      FOR routine_rec IN
        SELECT p.oid::regprocedure::text AS signature
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'platform'
      LOOP
        BEGIN
          EXECUTE format('ALTER ROUTINE %s OWNER TO serviceradar', routine_rec.signature);
        EXCEPTION
          WHEN OTHERS THEN
            RAISE NOTICE 'Skipping routine ownership update for %', routine_rec.signature;
        END;
      END LOOP;

      EXECUTE 'GRANT USAGE, CREATE ON SCHEMA platform TO serviceradar';
      EXECUTE 'GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA platform TO serviceradar';
      EXECUTE 'GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA platform TO serviceradar';
      EXECUTE 'GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA platform TO serviceradar';
      EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA platform GRANT ALL ON TABLES TO serviceradar';
      EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA platform GRANT ALL ON SEQUENCES TO serviceradar';
      EXECUTE 'ALTER DEFAULT PRIVILEGES IN SCHEMA platform GRANT ALL ON FUNCTIONS TO serviceradar';
    END
    $$;
    """)
  end

  def down do
    :ok
  end
end
