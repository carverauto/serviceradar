defmodule ServiceRadar.Repo.Migrations.MovePublicSchemaObjectsToPlatform do
  use Ecto.Migration

  def up do
    execute("CREATE SCHEMA IF NOT EXISTS platform")

    execute("""
    DO $$
    DECLARE
      rec record;
      pk_cols text;
      col_list text;
      public_has_rows boolean;
      platform_has_rows boolean;
      target_name text;
      suffix integer;
    BEGIN
      -- Move tables owned by the current user out of public.
      FOR rec IN
        SELECT tablename
        FROM pg_tables
        WHERE schemaname = 'public'
          AND tableowner = current_user
          AND tablename <> 'schema_migrations'
      LOOP
        IF to_regclass(format('platform.%I', rec.tablename)) IS NULL THEN
          EXECUTE format('ALTER TABLE public.%I SET SCHEMA platform', rec.tablename);
        ELSE
          EXECUTE format('SELECT EXISTS (SELECT 1 FROM public.%I LIMIT 1)', rec.tablename)
            INTO public_has_rows;
          EXECUTE format('SELECT EXISTS (SELECT 1 FROM platform.%I LIMIT 1)', rec.tablename)
            INTO platform_has_rows;

          IF public_has_rows IS NOT TRUE THEN
            EXECUTE format('DROP TABLE public.%I', rec.tablename);
          ELSIF platform_has_rows IS NOT TRUE THEN
            EXECUTE format('INSERT INTO platform.%I SELECT * FROM public.%I', rec.tablename, rec.tablename);
            EXECUTE format('DROP TABLE public.%I', rec.tablename);
          ELSE
            SELECT string_agg(format('%I', a.attname), ', ' ORDER BY a.attnum)
              INTO pk_cols
              FROM pg_index i
              JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
             WHERE i.indrelid = format('platform.%I', rec.tablename)::regclass
               AND i.indisprimary;

            SELECT string_agg(format('%I', c.column_name), ', ' ORDER BY c.ordinal_position)
              INTO col_list
              FROM information_schema.columns c
             WHERE c.table_schema = 'platform'
               AND c.table_name = rec.tablename
               AND EXISTS (
                 SELECT 1 FROM information_schema.columns c2
                  WHERE c2.table_schema = 'public'
                    AND c2.table_name = rec.tablename
                    AND c2.column_name = c.column_name
               );

            IF pk_cols IS NOT NULL AND col_list IS NOT NULL THEN
              EXECUTE format(
                'INSERT INTO platform.%I (%s) SELECT %s FROM public.%I ON CONFLICT (%s) DO NOTHING',
                rec.tablename,
                col_list,
                col_list,
                rec.tablename,
                pk_cols
              );
              EXECUTE format('DROP TABLE public.%I', rec.tablename);
            ELSE
              target_name := rec.tablename || '_public_backup';
              suffix := 1;

              WHILE to_regclass(format('platform.%I', target_name)) IS NOT NULL LOOP
                target_name := rec.tablename || '_public_backup_' || suffix;
                suffix := suffix + 1;
              END LOOP;

              EXECUTE format('ALTER TABLE public.%I SET SCHEMA platform', rec.tablename);
              EXECUTE format('ALTER TABLE platform.%I RENAME TO %I', rec.tablename, target_name);
              RAISE NOTICE 'Moved public.% to platform.% to avoid collision', rec.tablename, target_name;
            END IF;
          END IF;
        END IF;
      END LOOP;

      -- Move sequences owned by the current user out of public.
      FOR rec IN
        SELECT sequencename
        FROM pg_sequences
        WHERE schemaname = 'public'
          AND sequenceowner = current_user
      LOOP
        IF to_regclass(format('platform.%I', rec.sequencename)) IS NULL THEN
          EXECUTE format('ALTER SEQUENCE public.%I SET SCHEMA platform', rec.sequencename);
        ELSE
          EXECUTE format('DROP SEQUENCE public.%I', rec.sequencename);
        END IF;
      END LOOP;

      -- Move views owned by the current user out of public.
      FOR rec IN
        SELECT viewname
        FROM pg_views
        WHERE schemaname = 'public'
          AND viewowner = current_user
      LOOP
        IF to_regclass(format('platform.%I', rec.viewname)) IS NULL THEN
          EXECUTE format('ALTER VIEW public.%I SET SCHEMA platform', rec.viewname);
        ELSE
          EXECUTE format('DROP VIEW public.%I', rec.viewname);
        END IF;
      END LOOP;

      -- Move materialized views owned by the current user out of public.
      FOR rec IN
        SELECT matviewname
        FROM pg_matviews
        WHERE schemaname = 'public'
          AND matviewowner = current_user
      LOOP
        IF to_regclass(format('platform.%I', rec.matviewname)) IS NULL THEN
          EXECUTE format('ALTER MATERIALIZED VIEW public.%I SET SCHEMA platform', rec.matviewname);
        ELSE
          EXECUTE format('DROP MATERIALIZED VIEW public.%I', rec.matviewname);
        END IF;
      END LOOP;
    END $$;
    """)
  end

  def down do
    :ok
  end
end
