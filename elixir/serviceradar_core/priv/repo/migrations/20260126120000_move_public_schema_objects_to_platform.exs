defmodule ServiceRadar.Repo.Migrations.MovePublicSchemaObjectsToPlatform do
  @moduledoc """
  Moves objects the application owns out of `public` and into `platform`.

  Every relocation here needs ACCESS EXCLUSIVE on the object it moves, so any
  other session holding even ACCESS SHARE on one of them blocks this migration.
  Without a lock timeout that wait is unbounded, and under `MIX_ENV=test` the
  Sandbox `ownership_timeout` fires first: the connection is killed mid-migration
  and the run dies inside `do_lock_for_migrations/5` with
  `{:error, :rollback}` -- an error that names neither the object nor the
  blocker, and that reports the full ownership window as migration time (264s
  for work measured at ~340ms).

  `lock_timeout` bounds that wait so the migration fails in seconds and says
  which object it could not lock and which sessions were holding it. See
  issue #4151.
  """

  use Ecto.Migration

  # Deliberately short. Nothing here should ever wait on a lock in a healthy
  # migration: the objects being moved belong to an application that is not
  # supposed to be running yet. Waiting is the symptom, not something to be
  # patient about. Override for environments where a brief overlap is expected.
  @default_lock_timeout_ms 15_000

  defp lock_timeout_ms do
    case System.get_env("SERVICERADAR_MIGRATION_LOCK_TIMEOUT_MS") do
      nil ->
        @default_lock_timeout_ms

      value ->
        case Integer.parse(value) do
          {parsed, ""} when parsed > 0 -> parsed
          _ -> @default_lock_timeout_ms
        end
    end
  end

  def up do
    # SET LOCAL: scoped to this migration's transaction, so it cannot leak into
    # later migrations or into the connection when it returns to the pool.
    execute("SET LOCAL lock_timeout = '#{lock_timeout_ms()}ms'")

    execute("CREATE SCHEMA IF NOT EXISTS platform")

    execute(move_objects_sql(ledger_tables(repo().config()[:migration_source])))
  end

  @doc """
  Tables holding migration bookkeeping, which this migration MUST NOT relocate.

  Ecto names its ledger from the repo's `:migration_source`, defaulting to
  `schema_migrations`. `elixir/web-ng/config/config.exs` sets it to
  `ash_schema_migrations` for the shared `ServiceRadar.Repo`, so a hardcoded
  exclusion is correct for one entry point and wrong for the other -- which is
  exactly the bug in issue #4151.

  Relocating the ledger cannot work while a migration is running, whatever it is
  called. `Ecto.Migrator` takes `LOCK TABLE <ledger> IN SHARE UPDATE EXCLUSIVE`
  on one connection and then runs the migration body in a `Task.async`, which is
  a second connection. The body's `ALTER TABLE ... SET SCHEMA` needs
  `ACCESS EXCLUSIVE`, so it waits on a lock that will not be released until the
  body returns. Postgres cannot break it -- the holder is idle in transaction,
  waiting on the BEAM rather than on the database, so there is no cycle to
  detect -- and `Task.await(:infinity)` means the BEAM will not break it either.

  Nothing is lost by leaving the ledger where Ecto put it:
  `ServiceRadar.Cluster.StartupMigrations` already creates
  `platform.ash_schema_migrations` and syncs rows into it.
  """
  def ledger_tables(migration_source) do
    ["schema_migrations", migration_source]
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.uniq()
  end

  @doc false
  def move_objects_sql(ledger_tables) do
    ledger_list = Enum.map_join(ledger_tables, ", ", &"'#{String.replace(&1, "'", "''")}'")

    """
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
          AND tablename <> ALL (ARRAY[#{ledger_list}])
      LOOP
        IF to_regclass(format('platform.%I', rec.tablename)) IS NULL THEN
          -- lock_timeout turns an unbounded wait into an error; this block turns
          -- that error into a diagnosis. Postgres would otherwise report only
          -- "canceling statement due to lock timeout", naming neither the table
          -- nor the session responsible, which is what made #4151 take so long
          -- to characterise.
          BEGIN
            EXECUTE format('ALTER TABLE public.%I SET SCHEMA platform', rec.tablename);
          EXCEPTION WHEN lock_not_available THEN
            RAISE EXCEPTION
              'could not acquire ACCESS EXCLUSIVE on public.% within %',
              rec.tablename, current_setting('lock_timeout')
              USING
                DETAIL = format(
                  'conflicting lock holders: %s',
                  coalesce(
                    (SELECT string_agg(
                       format('pid=%s state=%s query=%s', a.pid, a.state, left(a.query, 120)),
                       '; ')
                       FROM pg_locks l
                       JOIN pg_stat_activity a ON a.pid = l.pid
                      WHERE l.relation = format('public.%I', rec.tablename)::regclass
                        AND l.pid <> pg_backend_pid()
                        AND l.granted),
                    'none still holding; the blocker released it after the timeout'
                  )
                ),
                HINT =
                  'Something is using this table while the migration tries to move it. '
                  'Stop the application against this database before migrating, or raise '
                  'SERVICERADAR_MIGRATION_LOCK_TIMEOUT_MS if a brief overlap is expected.';
          END;
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
    """
  end

  def down do
    :ok
  end
end
