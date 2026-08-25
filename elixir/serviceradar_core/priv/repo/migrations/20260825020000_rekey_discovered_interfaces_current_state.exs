defmodule ServiceRadar.Repo.Migrations.RekeyDiscoveredInterfacesCurrentState do
  @moduledoc """
  Persist one current-state row per `(device_id, interface_uid)`.

  `platform.discovered_interfaces` is a Timescale hypertable whose primary
  key includes `timestamp`. That identity IS the append-only mechanism: every
  poll inserts. A unique index on `(device_id, interface_uid)` cannot exist on
  a hypertable (Timescale requires the partition column in every unique
  index), so current-state means converting to a regular table.

  The latest observation per key is kept. Historical restatements are
  discarded: they were never a deliberate history store. Per-poll provenance
  made every row byte-distinct, so there is no "true row" to keep. A
  change-only history table is a later change (OpenSpec task 4, GitHub #4021).

  The 3-day hypertable retention policy is removed with the hypertable.
  Current-state rows must not expire.
  """
  use Ecto.Migration

  @disable_ddl_transaction false

  def up do
    execute("""
    DO $$
    DECLARE
      ts_schema text;
      is_hyper boolean := false;
    BEGIN
      SELECT n.nspname
      INTO ts_schema
      FROM pg_extension e
      JOIN pg_namespace n ON n.oid = e.extnamespace
      WHERE e.extname = 'timescaledb';

      IF ts_schema IS NOT NULL THEN
        SELECT EXISTS (
          SELECT 1
          FROM timescaledb_information.hypertables
          WHERE hypertable_schema = '#{prefix() || "platform"}'
            AND hypertable_name = 'discovered_interfaces'
        ) INTO is_hyper;

        IF is_hyper THEN
          EXECUTE format(
            'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
            ts_schema,
            '#{prefix() || "platform"}.discovered_interfaces'
          );
        END IF;
      END IF;
    END
    $$;
    """)

    execute("""
    CREATE TABLE #{prefix() || "platform"}.discovered_interfaces_current
      (LIKE #{prefix() || "platform"}.discovered_interfaces INCLUDING DEFAULTS INCLUDING COMMENTS)
    """)

    execute("""
    INSERT INTO #{prefix() || "platform"}.discovered_interfaces_current
    SELECT DISTINCT ON (device_id, interface_uid) *
    FROM #{prefix() || "platform"}.discovered_interfaces
    ORDER BY device_id, interface_uid, timestamp DESC, created_at DESC NULLS LAST
    """)

    execute("DROP TABLE #{prefix() || "platform"}.discovered_interfaces CASCADE")

    execute("""
    ALTER TABLE #{prefix() || "platform"}.discovered_interfaces_current
      RENAME TO discovered_interfaces
    """)

    execute("""
    ALTER TABLE #{prefix() || "platform"}.discovered_interfaces
      ADD PRIMARY KEY (device_id, interface_uid)
    """)

    execute("""
    ALTER TABLE #{prefix() || "platform"}.discovered_interfaces
      ADD CONSTRAINT discovered_interfaces_device_id_fkey
      FOREIGN KEY (device_id) REFERENCES #{prefix() || "platform"}.ocsf_devices(uid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device
      ON #{prefix() || "platform"}.discovered_interfaces (device_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device_if_index
      ON #{prefix() || "platform"}.discovered_interfaces (device_id, if_index)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS discovered_interfaces_metadata_gin_idx
      ON #{prefix() || "platform"}.discovered_interfaces
      USING GIN (metadata)
    """)
  end

  def down do
    raise "cannot restore discarded historical interface observations"
  end
end
