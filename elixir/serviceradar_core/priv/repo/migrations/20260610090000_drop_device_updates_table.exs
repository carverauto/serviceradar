defmodule ServiceRadar.Repo.Migrations.DropDeviceUpdatesTable do
  @moduledoc """
  Drops the dead `device_updates` hypertable.

  The table was created as a device history log but no writer was ever
  implemented anywhere in the stack (Elixir, Go, or Rust), so it has held
  zero rows since creation while still being exposed through SRQL. Device
  history will be redesigned later as part of an append-only observation
  store (see openspec/changes/refactor-device-identity-reconciliation).

  The up migration removes the TimescaleDB retention policy first (if one
  exists), then drops the table. Both steps are guarded and idempotent.

  The down migration recreates the original (empty) table, converts it back
  to a hypertable when TimescaleDB is available, and restores the 30 day
  retention policy, mirroring 20260117100000_create_timeseries_tables.exs
  and 20260129154221_add_observability_retention_policies.exs.
  """
  use Ecto.Migration

  # serviceradar:allow-startup-maintenance - device_updates never had a writer (verified empty),
  # so dropping it and reconciling its retention policy is metadata-only and idempotent.

  def up do
    remove_retention_policy()

    execute("DROP TABLE IF EXISTS #{prefix() || "platform"}.device_updates")
  end

  def down do
    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix() || "platform"}.device_updates (
      observed_at      TIMESTAMPTZ NOT NULL,
      agent_id         TEXT        NOT NULL DEFAULT '',
      gateway_id       TEXT        NOT NULL DEFAULT '',
      partition        TEXT        NOT NULL DEFAULT 'default',
      device_id        TEXT        NOT NULL,
      discovery_source TEXT        NOT NULL DEFAULT 'unknown',
      ip               TEXT,
      mac              TEXT,
      hostname         TEXT,
      available        BOOLEAN,
      metadata         JSONB,
      created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (observed_at, device_id)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_device_updates_device
      ON #{prefix() || "platform"}.device_updates (device_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_device_updates_timestamp
      ON #{prefix() || "platform"}.device_updates (observed_at DESC)
    """)

    maybe_create_hypertable()
    add_retention_policy()
  end

  defp remove_retention_policy do
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

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{prefix() || "platform"}'
             AND hypertable_name = 'device_updates'
         ) THEN
        EXECUTE format(
          'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
          ts_schema,
          format('%I.%I', '#{prefix() || "platform"}', 'device_updates')
        );
        RAISE NOTICE 'Removed retention policy from device_updates';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not remove retention policy from device_updates: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp maybe_create_hypertable do
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

      IF ts_schema IS NOT NULL THEN
        EXECUTE format(
          'SELECT %I.create_hypertable(%L::regclass, %L, if_not_exists => true, migrate_data => true)',
          ts_schema,
          format('%I.%I', '#{prefix() || "platform"}', 'device_updates'),
          'observed_at'
        );
        RAISE NOTICE 'Converted device_updates back to a hypertable';
      ELSE
        RAISE NOTICE 'TimescaleDB not available - device_updates recreated as a plain table';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not convert device_updates to a hypertable: %', SQLERRM;
    END;
    $$;
    """)
  end

  defp add_retention_policy do
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

      IF ts_schema IS NOT NULL
         AND EXISTS (
           SELECT 1
           FROM timescaledb_information.hypertables
           WHERE hypertable_schema = '#{prefix() || "platform"}'
             AND hypertable_name = 'device_updates'
         ) THEN
        EXECUTE format(
          'SELECT %I.add_retention_policy(%L::regclass, INTERVAL ''30 days'', if_not_exists => true)',
          ts_schema,
          format('%I.%I', '#{prefix() || "platform"}', 'device_updates')
        );
        RAISE NOTICE 'Added 30 days retention policy to device_updates';
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not add retention policy to device_updates: %', SQLERRM;
    END;
    $$;
    """)
  end
end
