defmodule ServiceRadar.Repo.Migrations.CreateNetflowMetricsHypertable do
  @moduledoc """
  Creates netflow_metrics hypertable for raw NetFlow/IPFIX metrics with BGP routing information.

  This table stores NetFlow metrics for network analysis and BGP routing visibility,
  separate from the OCSF-normalized ocsf_network_activity table used for security analysis.

  ## Data Flow
  Rust netflow-collector → NATS (flows.raw.netflow) → EventWriter NetFlowMetrics processor → this table

  ## BGP Fields
  - `as_path`: Array of AS numbers in routing sequence (SOURCE_AS → INTERMEDIATE_AS → DEST_AS)
  - `bgp_communities`: Array of 32-bit BGP community values (RFC 1997 format: ASN:value)

  ## Indexes
  - GIN indexes on as_path and bgp_communities enable fast containment queries (e.g., WHERE as_path @> ARRAY[64512])
  - BTREE index on timestamp for time-range queries
  """

  use Ecto.Migration

  @prefix "platform"

  def up do
    # Create netflow_metrics table
    execute("""
    CREATE TABLE IF NOT EXISTS #{@prefix}.netflow_metrics (
      timestamp          TIMESTAMPTZ NOT NULL,
      src_ip             INET,
      dst_ip             INET,
      sampler_address    INET,
      src_port           INTEGER,
      dst_port           INTEGER,
      protocol           INTEGER,
      bytes_total        BIGINT,
      packets_total      BIGINT,
      as_path            INTEGER[],
      bgp_communities    INTEGER[],
      partition          TEXT NOT NULL DEFAULT 'default',
      metadata           JSONB,
      created_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
      PRIMARY KEY (timestamp, src_ip, dst_ip, protocol, src_port, dst_port)
    )
    """)

    # Ensure table ownership
    ensure_table_ownership("netflow_metrics")

    # Convert to TimescaleDB hypertable if available
    maybe_create_hypertable("netflow_metrics", "timestamp")

    # Create GIN index for AS path containment queries
    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_metrics_as_path
    ON #{@prefix}.netflow_metrics USING GIN (as_path)
    """)

    # Create GIN index for BGP communities containment queries
    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_metrics_bgp_communities
    ON #{@prefix}.netflow_metrics USING GIN (bgp_communities)
    """)

    # Create BTREE index on timestamp for time-range queries
    execute("""
    CREATE INDEX IF NOT EXISTS idx_netflow_metrics_timestamp
    ON #{@prefix}.netflow_metrics (timestamp DESC)
    """)

    # Add column comments
    execute("""
    COMMENT ON COLUMN #{@prefix}.netflow_metrics.as_path IS
    'BGP AS path sequence (source AS → intermediate AS → destination AS). Array of AS numbers from IPFIX fields.'
    """)

    execute("""
    COMMENT ON COLUMN #{@prefix}.netflow_metrics.bgp_communities IS
    'BGP community values in 32-bit format (high 16 bits = AS number, low 16 bits = value). Standard communities per RFC 1997.'
    """)

    execute("""
    COMMENT ON COLUMN #{@prefix}.netflow_metrics.metadata IS
    'Extensibility field for unmapped FlowMessage protobuf fields (interfaces, VLANs, sampling rate, etc.)'
    """)

    execute("""
    COMMENT ON TABLE #{@prefix}.netflow_metrics IS
    'Raw NetFlow/IPFIX metrics with BGP routing information for network analysis. Separate from OCSF-normalized flow for different query patterns.'
    """)
  end

  def down do
    # Drop indexes first
    execute("DROP INDEX IF EXISTS #{@prefix}.idx_netflow_metrics_timestamp")
    execute("DROP INDEX IF EXISTS #{@prefix}.idx_netflow_metrics_bgp_communities")
    execute("DROP INDEX IF EXISTS #{@prefix}.idx_netflow_metrics_as_path")

    # Drop table
    execute("DROP TABLE IF EXISTS #{@prefix}.netflow_metrics")
  end

  # Helper to conditionally create hypertable (idempotent)
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

      -- Only try if TimescaleDB extension exists
      IF ts_schema IS NOT NULL THEN
        -- Only convert if not already a hypertable
        IF NOT EXISTS (
          SELECT 1 FROM timescaledb_information.hypertables
          WHERE hypertable_name = '#{table_name}'
          AND hypertable_schema = '#{@prefix}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{@prefix}.#{table_name}',
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

  # Helper to ensure table ownership matches current user (idempotent)
  defp ensure_table_ownership(table_name) do
    execute("""
    DO $$
    BEGIN
      -- Only change ownership if table exists and current user is not already owner
      IF EXISTS (
        SELECT 1 FROM pg_tables
        WHERE tablename = '#{table_name}'
        AND schemaname = '#{@prefix}'
      ) THEN
        EXECUTE format('ALTER TABLE %I.%I OWNER TO CURRENT_USER', '#{@prefix}', '#{table_name}');
      END IF;
    EXCEPTION
      WHEN others THEN
        RAISE NOTICE 'Could not change ownership for #{table_name}: %', SQLERRM;
    END;
    $$;
    """)
  end
end
