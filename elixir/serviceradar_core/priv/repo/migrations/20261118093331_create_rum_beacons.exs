defmodule ServiceRadar.Repo.Migrations.CreateRumBeacons do
  @moduledoc """
  Creates `platform.rum_beacons`, the CNPG hypertable for Boomerang RUM beacons
  when StarRocks is disabled.

  With StarRocks enabled, EventWriter writes `rum.beacons.>` strictly to the
  StarRocks table `serviceradar.rum_beacons` (priv/starrocks/0043_rum_beacons.sql)
  and never to CNPG. Retention is managed by `ServiceRadar.Observability.DataRetentionWorker`.
  """

  use Ecto.Migration

  @table "rum_beacons"

  def up do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.#{@table} (
      web_property_id text NOT NULL,
      observed_at timestamptz NOT NULL,
      beacon_id text NOT NULL,
      canonical_origin text,
      environment text,
      url text,
      host text,
      path text,
      metric_path text,
      referrer text,
      page_group text,
      initiator text,
      trace_id text,
      span_id text,
      session_id text,
      user_agent text,
      device_type text,
      browser text,
      os text,
      lcp_ms double precision,
      inp_ms double precision,
      cls double precision,
      fcp_ms double precision,
      ttfb_ms double precision,
      page_load_ms double precision,
      dns_ms double precision,
      connect_ms double precision,
      tls_ms double precision,
      dom_ready_ms double precision,
      rage_clicks integer NOT NULL DEFAULT 0,
      js_errors integer NOT NULL DEFAULT 0,
      http_status integer NOT NULL DEFAULT 0,
      has_error boolean NOT NULL DEFAULT false,
      cdn_provider text,
      cdn_cache_status text,
      cdn_edge_rtt_ms double precision,
      cdn_origin_rtt_ms double precision,
      cdn_pop text,
      server_timing_raw text,
      client_ip text,
      client_ip_anonymized boolean NOT NULL DEFAULT true,
      country text,
      region text,
      city text,
      asn integer,
      as_org text,
      prefix_tag text,
      attributes jsonb NOT NULL DEFAULT '{}'::jsonb,
      created_at timestamptz NOT NULL DEFAULT now()
    )
    """)

    execute("""
    CREATE UNIQUE INDEX IF NOT EXISTS rum_beacons_identity_idx
      ON #{schema()}.#{@table} (web_property_id, beacon_id, observed_at)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS rum_beacons_observed_at_idx
      ON #{schema()}.#{@table} (observed_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS rum_beacons_property_time_idx
      ON #{schema()}.#{@table} (web_property_id, observed_at DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS rum_beacons_trace_id_idx
      ON #{schema()}.#{@table} (trace_id) WHERE trace_id IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS rum_beacons_prefix_tag_idx
      ON #{schema()}.#{@table} (prefix_tag) WHERE prefix_tag IS NOT NULL
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
            'SELECT %I.create_hypertable(%L::regclass, %L::name, chunk_time_interval => INTERVAL ''1 day'', create_default_indexes => false, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{schema()}.#{@table}',
            'observed_at'
          );
        END IF;
      END IF;
    END;
    $$;
    """)
  end
end
