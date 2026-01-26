defmodule ServiceRadar.Repo.Migrations.MovePublicSchemaObjectsToPlatform do
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    execute("""
    DO $$
    DECLARE
      rec record;
    BEGIN
      -- Move tables owned by the current user out of public.
      FOR rec IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'public'
          AND tableowner = current_user
          AND tablename <> 'schema_migrations'
      LOOP
        EXECUTE format('ALTER TABLE public.%I SET SCHEMA platform', rec.tablename);
      END LOOP;

      -- Move sequences owned by the current user out of public.
      FOR rec IN
        SELECT sequencename
        FROM pg_sequences
        WHERE schemaname = 'public'
          AND sequenceowner = current_user
      LOOP
        EXECUTE format('ALTER SEQUENCE public.%I SET SCHEMA platform', rec.sequencename);
      END LOOP;

      -- Move views owned by the current user out of public.
      FOR rec IN
        SELECT viewname
        FROM pg_views
        WHERE schemaname = 'public'
          AND viewowner = current_user
      LOOP
        EXECUTE format('ALTER VIEW public.%I SET SCHEMA platform', rec.viewname);
      END LOOP;

      -- Move materialized views owned by the current user out of public.
      FOR rec IN
        SELECT matviewname
        FROM pg_matviews
        WHERE schemaname = 'public'
          AND matviewowner = current_user
      LOOP
        EXECUTE format('ALTER MATERIALIZED VIEW public.%I SET SCHEMA platform', rec.matviewname);
      END LOOP;
    END $$;
    """)
  end

  def down do
    :ok
  end
end
