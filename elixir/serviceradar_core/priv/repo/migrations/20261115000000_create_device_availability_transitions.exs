defmodule ServiceRadar.Repo.Migrations.CreateDeviceAvailabilityTransitions do
  @moduledoc """
  Creates `platform.device_availability_transitions`, the CNPG store of the merged device
  availability history (OpenSpec fix-device-availability-timeline, design Decision 2).

  One row per change of a device's merged availability state: the device was `from_state`
  from `from_since` (NULL when it had no earlier decision) until `changed_at`, when it
  became `to_state`. EventWriter's AvailabilityTransitions processor writes it, from
  JetStream, only while StarRocks is disabled; with StarRocks enabled the warehouse table
  of the same shape (priv/starrocks/0042) is the only store.

  `(device_uid, changed_at, to_state)` is the record's identity, the one its message id is
  derived from, so a redelivered or republished record is inserted once. It includes the
  hypertable's time column, as TimescaleDB requires of a unique index. Retention is the
  CNPG telemetry path's (`ServiceRadar.Observability.DataRetentionWorker`, capped by the
  telemetry ceiling).
  """

  use Ecto.Migration

  @table "device_availability_transitions"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@table} (
      device_uid text NOT NULL,
      changed_at timestamptz NOT NULL,
      to_state text NOT NULL,
      from_state text NOT NULL,
      from_since timestamptz,
      authority_class text,
      source_kind text,
      reporter_agent_id text,
      rule text,
      conflict boolean NOT NULL DEFAULT false,
      created_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT device_availability_transitions_states CHECK (
        from_state IN ('available', 'unavailable', 'unknown')
        AND to_state IN ('available', 'unavailable', 'unknown')
      )
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS device_availability_transitions_identity_idx
      ON #{schema()}.#{@table} (device_uid, changed_at, to_state)
    """)

    maybe_create_hypertable()
  end

  def down do
    execute("DROP TABLE IF EXISTS #{schema()}.#{@table}")
  end

  defp schema, do: prefix() || "platform"

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
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_name = '#{@table}'
            AND hypertable_schema = '#{schema()}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, chunk_time_interval => INTERVAL ''7 days'', create_default_indexes => false, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{schema()}.#{@table}',
            'changed_at'
          );
        END IF;
      END IF;
    END;
    $$;
    """)
  end
end
