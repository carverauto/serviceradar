defmodule ServiceRadar.Repo.Migrations.RekeyDiscoveredInterfacesCurrentState do
  @moduledoc """
  Persist one current-state row per `(device_id, interface_uid)`.

  `platform.discovered_interfaces` is a Timescale hypertable whose primary
  key includes `timestamp`. That identity IS the append-only mechanism: every
  poll inserts. A unique index on `(device_id, interface_uid)` cannot exist on
  a hypertable (Timescale requires the partition column in every unique
  index), so current-state means converting to a regular table.

  The latest observation per key supplies `timestamp`, metadata, and the
  other last-observed columns. Historical restatements are discarded: they
  were never a deliberate history store. Per-poll provenance made every row
  byte-distinct, so there is no "true row" to keep. A change-only history
  table is a later change (OpenSpec task 4, GitHub #4021).

  Mapper-only operational columns are NOT taken from the latest row
  wholesale. A later sparse sync observation would NULL `if_index` (and the
  other eight) once current-state upserts; the live sync writer already
  refuses to list those fields. The collapse uses the same list: latest
  non-null wins for `if_index`, `if_speed`, `speed_bps`, `if_admin_status`,
  `if_oper_status`, `if_type`, `mtu`, `duplex`, `available_metrics`.

  The `INSERT … SELECT DISTINCT ON` of an unreaped table takes an exclusive
  lock for the copy. 3-day hypertable retention may not exist on every
  deploy (#4021's 4-device sample was "hypertable: no, retention: none").

  The 3-day hypertable retention policy is removed with the hypertable.
  Current-state rows must not expire.
  """
  use Ecto.Migration

  # Ecto default. The copy is one transaction; keep it that way so a failed
  # collapse cannot leave `discovered_interfaces_current` beside the source.
  @disable_ddl_transaction false

  # Same nine fields `InterfacesUpsertFieldsTest` pins as mapper-only. A
  # later sparse sync row must not blank them during collapse.
  @mapper_operational_columns ~w(
    if_index
    if_speed
    speed_bps
    if_admin_status
    if_oper_status
    if_type
    mtu
    duplex
    available_metrics
  )

  def up do
    schema = prefix() || "platform"
    source = "#{schema}.discovered_interfaces"
    dest = "#{schema}.discovered_interfaces_current"

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
          WHERE hypertable_schema = '#{schema}'
            AND hypertable_name = 'discovered_interfaces'
        ) INTO is_hyper;

        IF is_hyper THEN
          EXECUTE format(
            'SELECT %I.remove_retention_policy(%L::regclass, if_exists => true)',
            ts_schema,
            '#{source}'
          );
        END IF;
      END IF;
    END
    $$;
    """)

    execute("""
    CREATE TABLE #{dest}
      (LIKE #{source} INCLUDING DEFAULTS INCLUDING COMMENTS)
    """)

    execute("""
    INSERT INTO #{dest}
    SELECT DISTINCT ON (device_id, interface_uid) *
    FROM #{source}
    ORDER BY device_id, interface_uid, timestamp DESC, created_at DESC NULLS LAST
    """)

    execute(coalesce_mapper_columns_sql(source, dest))

    execute("DROP TABLE #{source} CASCADE")

    execute("""
    ALTER TABLE #{dest}
      RENAME TO discovered_interfaces
    """)

    execute("""
    ALTER TABLE #{source}
      ADD PRIMARY KEY (device_id, interface_uid)
    """)

    execute("""
    ALTER TABLE #{source}
      ADD CONSTRAINT discovered_interfaces_device_id_fkey
      FOREIGN KEY (device_id) REFERENCES #{schema}.ocsf_devices(uid)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device
      ON #{source} (device_id)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device_if_index
      ON #{source} (device_id, if_index)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS discovered_interfaces_metadata_gin_idx
      ON #{source}
      USING GIN (metadata)
    """)

    # DROP TABLE CASCADE removed the time-range indexes SRQL still uses
    # (`di.timestamp >= $1 AND di.timestamp <= $1`). timestamp is last-observed
    # now, not the hypertable partition column.
    execute("""
    CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_timestamp
      ON #{source} (timestamp DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_discovered_interfaces_device_time
      ON #{source} (device_id, timestamp DESC)
    """)
  end

  def down do
    raise "cannot restore discarded historical interface observations"
  end

  @doc false
  def mapper_operational_columns, do: @mapper_operational_columns

  @doc """
  Overlay latest-non-null mapper operational columns onto the latest-row copy.

  Public so the migration test can run the same SQL against temp tables.
  """
  def coalesce_mapper_columns_sql(source_rel, dest_rel) do
    assigns =
      Enum.map_join(@mapper_operational_columns, ",\n      ", fn col ->
        "#{col} = c.#{col}"
      end)

    aggs =
      Enum.map_join(@mapper_operational_columns, ",\n        ", fn col ->
        latest_non_null_agg(col)
      end)

    """
    UPDATE #{dest_rel} AS d
    SET
      #{assigns}
    FROM (
      SELECT
        device_id,
        interface_uid,
        #{aggs}
      FROM #{source_rel}
      GROUP BY device_id, interface_uid
    ) AS c
    WHERE d.device_id = c.device_id
      AND d.interface_uid = c.interface_uid
    """
  end

  # `array_agg(jsonb[])[1]` is jsonb, not jsonb[]: PostgreSQL concatenates
  # array inputs, so the subscript is one element of the inner array. Round
  # the whole value through text so latest-non-null keeps the mapper array.
  defp latest_non_null_agg("available_metrics") do
    "(array_agg(available_metrics::text ORDER BY timestamp DESC, created_at DESC NULLS LAST) " <>
      "FILTER (WHERE available_metrics IS NOT NULL))[1]::jsonb[] AS available_metrics"
  end

  defp latest_non_null_agg(col) do
    "(array_agg(#{col} ORDER BY timestamp DESC, created_at DESC NULLS LAST) " <>
      "FILTER (WHERE #{col} IS NOT NULL))[1] AS #{col}"
  end
end
