defmodule ServiceRadar.Repo.Migrations.ShrinkOcsfEventsChunkInterval do
  @moduledoc false
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL
         OR NOT EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = 'ocsf_events'
         ) THEN
        RAISE NOTICE 'Skipping ocsf_events chunk interval - not a hypertable or TimescaleDB not available';
        RETURN;
      END IF;

      EXECUTE format(
        'SELECT %I.set_chunk_time_interval(%L::regclass, INTERVAL ''24 hours'')',
        ts_schema,
        'platform.ocsf_events'
      );

      RAISE NOTICE 'Shrunk ocsf_events chunk interval to 24 hours';
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not shrink ocsf_events chunk interval: %', SQLERRM;
    END;
    $$;
    """)
  end

  def down do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NULL
         OR NOT EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = 'platform'
             AND hypertable_name = 'ocsf_events'
         ) THEN
        RETURN;
      END IF;

      EXECUTE format(
        'SELECT %I.set_chunk_time_interval(%L::regclass, INTERVAL ''7 days'')',
        ts_schema,
        'platform.ocsf_events'
      );
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not restore ocsf_events chunk interval: %', SQLERRM;
    END;
    $$;
    """)
  end
end
