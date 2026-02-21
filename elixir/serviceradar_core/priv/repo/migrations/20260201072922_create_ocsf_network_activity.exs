defmodule ServiceRadar.Repo.Migrations.CreateOcsfNetworkActivity do
  @moduledoc """
  Creates the OCSF Network Activity hypertable for flow telemetry.

  This migration is idempotent and safe to re-run.
  """
  use Ecto.Migration

  @table "ocsf_network_activity"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{prefix() || "platform"}.#{@table} (
      time                 TIMESTAMPTZ       NOT NULL,
      class_uid            INTEGER           NOT NULL DEFAULT 4001,
      category_uid         INTEGER           NOT NULL DEFAULT 4,
      activity_id          INTEGER           NOT NULL DEFAULT 6,
      type_uid             INTEGER           NOT NULL DEFAULT 400106,
      severity_id          INTEGER           NOT NULL DEFAULT 1,
      start_time           TIMESTAMPTZ,
      end_time             TIMESTAMPTZ,
      src_endpoint_ip      TEXT,
      src_endpoint_port    INTEGER,
      src_as_number        INTEGER,
      dst_endpoint_ip      TEXT,
      dst_endpoint_port    INTEGER,
      dst_as_number        INTEGER,
      protocol_num         INTEGER,
      protocol_name        TEXT,
      tcp_flags            INTEGER,
      bytes_total          BIGINT,
      packets_total        BIGINT,
      bytes_in             BIGINT,
      bytes_out            BIGINT,
      sampler_address      TEXT,
      ocsf_payload         JSONB             NOT NULL,
      partition            TEXT              DEFAULT 'default',
      created_at           TIMESTAMPTZ       NOT NULL DEFAULT now()
    )
    """)

    maybe_create_hypertable(@table, "time")

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_src_ip_time
      ON #{prefix() || "platform"}.#{@table} (src_endpoint_ip, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_dst_ip_time
      ON #{prefix() || "platform"}.#{@table} (dst_endpoint_ip, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_proto_time
      ON #{prefix() || "platform"}.#{@table} (protocol_num, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_src_port_time
      ON #{prefix() || "platform"}.#{@table} (src_endpoint_port, time DESC)
      WHERE src_endpoint_port IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_dst_port_time
      ON #{prefix() || "platform"}.#{@table} (dst_endpoint_port, time DESC)
      WHERE dst_endpoint_port IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_sampler_time
      ON #{prefix() || "platform"}.#{@table} (sampler_address, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_payload_gin
      ON #{prefix() || "platform"}.#{@table} USING gin (ocsf_payload)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_top_talkers
      ON #{prefix() || "platform"}.#{@table} (time DESC, src_endpoint_ip, bytes_total)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_top_ports
      ON #{prefix() || "platform"}.#{@table} (time DESC, dst_endpoint_port, bytes_total)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_ocsf_network_activity_partition
      ON #{prefix() || "platform"}.#{@table} (partition, time DESC)
    """)

    execute("""
    COMMENT ON TABLE #{prefix() || "platform"}.#{@table} IS
      'OCSF 1.7.0 Network Activity events from NetFlow/IPFIX collectors'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix() || "platform"}.#{@table}.time IS
      'Flow end time or receive time (ms since epoch)'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix() || "platform"}.#{@table}.class_uid IS
      'OCSF class UID (4001 = Network Activity)'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix() || "platform"}.#{@table}.activity_id IS
      'OCSF activity ID (6 = Traffic)'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix() || "platform"}.#{@table}.type_uid IS
      'OCSF type UID (400106 = Network Activity: Traffic)'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix() || "platform"}.#{@table}.ocsf_payload IS
      'Full OCSF event as JSON for complete event reconstruction'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix() || "platform"}.#{@table}.bytes_total IS
      'Total bytes transferred in flow'
    """)

    execute("""
    COMMENT ON COLUMN #{prefix() || "platform"}.#{@table}.packets_total IS
      'Total packets transferred in flow'
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_partition")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_top_ports")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_top_talkers")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_payload_gin")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_sampler_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_dst_port_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_src_port_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_proto_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_dst_ip_time")
    execute("DROP INDEX IF EXISTS #{prefix() || "platform"}.idx_ocsf_network_activity_src_ip_time")
    execute("DROP TABLE IF EXISTS #{prefix() || "platform"}.#{@table}")
  end

  defp maybe_create_hypertable(table_name, time_column) do
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
          WHERE hypertable_name = '#{table_name}'
            AND hypertable_schema = '#{prefix() || "platform"}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{prefix() || "platform"}.#{table_name}',
            '#{time_column}'
          );
          RAISE NOTICE 'Created hypertable for #{table_name}';
        END IF;
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not create hypertable for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
