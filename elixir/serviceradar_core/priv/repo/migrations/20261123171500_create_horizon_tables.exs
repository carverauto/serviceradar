defmodule ServiceRadar.Repo.Migrations.CreateHorizonTables do
  @moduledoc """
  Creates typed CNPG hypertables in `platform` for Horizon outages, BGP events,
  BGP zombie episodes, and path hop telemetry.

  These tables are populated via `EventWriter` projections and queried directly
  through SRQL entities (`in:horizon_outages`, `in:horizon_bgp`,
  `in:horizon_zombies`, and `in:horizon_paths`).
  """

  use Ecto.Migration

  @tables [
    "horizon_outages",
    "horizon_bgp_events",
    "horizon_bgp_zombies",
    "horizon_path_hops"
  ]

  def up do
    create_horizon_outages()
    create_horizon_bgp_events()
    create_horizon_bgp_zombies()
    create_horizon_path_hops()

    Enum.each(@tables, &maybe_create_hypertable(&1, "time"))
  end

  def down do
    Enum.each(Enum.reverse(@tables), fn table ->
      execute("DROP TABLE IF EXISTS #{schema()}.#{table}")
    end)
  end

  defp schema, do: prefix() || "platform"

  defp create_horizon_outages do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.horizon_outages (
      time                      TIMESTAMPTZ NOT NULL,
      outage_id                 TEXT        NOT NULL,
      status                    TEXT        NOT NULL,
      severity                  TEXT        NOT NULL,
      entity_type               TEXT        NOT NULL,
      entity_key                TEXT        NOT NULL,
      region                    TEXT,
      covering_prefix           TEXT,
      origin_asn                BIGINT,
      corroborating_pop_count   INTEGER     NOT NULL DEFAULT 0,
      avg_forwarding_loss_pct   DOUBLE PRECISION,
      avg_synthetic_failure_pct DOUBLE PRECISION,
      window_start_ms           BIGINT,
      window_end_ms             BIGINT,
      correlated_bgp_event_ids  JSONB       NOT NULL DEFAULT '[]'::jsonb,
      raw_data                  JSONB       NOT NULL DEFAULT '{}'::jsonb,
      PRIMARY KEY (time, outage_id)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_outages_time
      ON #{schema()}.horizon_outages (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_outages_outage_id
      ON #{schema()}.horizon_outages (outage_id, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_outages_status
      ON #{schema()}.horizon_outages (status, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_outages_covering_prefix
      ON #{schema()}.horizon_outages (covering_prefix)
      WHERE covering_prefix IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_outages_origin_asn
      ON #{schema()}.horizon_outages (origin_asn)
      WHERE origin_asn IS NOT NULL
    """)
  end

  defp create_horizon_bgp_events do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.horizon_bgp_events (
      time                 TIMESTAMPTZ NOT NULL,
      event_id             TEXT        NOT NULL,
      kind                 TEXT        NOT NULL,
      level                TEXT        NOT NULL,
      prefix               TEXT        NOT NULL,
      origin_asn           BIGINT,
      as_path              JSONB       NOT NULL DEFAULT '[]'::jsonb,
      rpki_status          TEXT,
      caida_leak_inference TEXT,
      watchlist_id         TEXT,
      client_label         TEXT,
      raw_data             JSONB       NOT NULL DEFAULT '{}'::jsonb,
      PRIMARY KEY (time, event_id)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_events_time
      ON #{schema()}.horizon_bgp_events (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_events_kind
      ON #{schema()}.horizon_bgp_events (kind, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_events_prefix
      ON #{schema()}.horizon_bgp_events (prefix)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_events_origin_asn
      ON #{schema()}.horizon_bgp_events (origin_asn)
      WHERE origin_asn IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_events_watchlist_id
      ON #{schema()}.horizon_bgp_events (watchlist_id)
      WHERE watchlist_id IS NOT NULL
    """)
  end

  defp create_horizon_bgp_zombies do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.horizon_bgp_zombies (
      time            TIMESTAMPTZ NOT NULL,
      episode_id      TEXT        NOT NULL,
      status          TEXT        NOT NULL,
      prefix          TEXT        NOT NULL,
      origin_asn      BIGINT,
      divergence_pct  DOUBLE PRECISION,
      is_beacon       BOOLEAN     NOT NULL DEFAULT false,
      withdrawn_peers INTEGER,
      total_peers     INTEGER,
      stuck_peer_asns JSONB       NOT NULL DEFAULT '[]'::jsonb,
      first_seen_at   TIMESTAMPTZ,
      resolved_at     TIMESTAMPTZ,
      raw_data        JSONB       NOT NULL DEFAULT '{}'::jsonb,
      PRIMARY KEY (time, episode_id)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_zombies_time
      ON #{schema()}.horizon_bgp_zombies (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_zombies_episode_id
      ON #{schema()}.horizon_bgp_zombies (episode_id, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_zombies_status
      ON #{schema()}.horizon_bgp_zombies (status, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_zombies_prefix
      ON #{schema()}.horizon_bgp_zombies (prefix)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_bgp_zombies_origin_asn
      ON #{schema()}.horizon_bgp_zombies (origin_asn)
      WHERE origin_asn IS NOT NULL
    """)
  end

  defp create_horizon_path_hops do
    execute("""
    CREATE TABLE IF NOT EXISTS #{schema()}.horizon_path_hops (
      time                   TIMESTAMPTZ NOT NULL,
      round_id               TEXT        NOT NULL,
      target_id              TEXT        NOT NULL,
      pop_id                 TEXT        NOT NULL,
      hop_ttl                INTEGER     NOT NULL,
      hop_ip                 TEXT,
      router_alias_id        TEXT,
      alias_confidence       DOUBLE PRECISION,
      asn                    BIGINT,
      as_org                 TEXT,
      is_cloud               BOOLEAN     NOT NULL DEFAULT false,
      cloud_provider         TEXT,
      cloud_region           TEXT,
      forwarding_loss_pct    DOUBLE PRECISION,
      avg_rtt_ms             DOUBLE PRECISION,
      effective_path_mtu     INTEGER,
      mtu_blackhole_detected BOOLEAN     NOT NULL DEFAULT false,
      blackhole_hop_ttl      INTEGER,
      raw_data               JSONB       NOT NULL DEFAULT '{}'::jsonb,
      PRIMARY KEY (time, round_id, target_id, pop_id, hop_ttl)
    )
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_path_hops_time
      ON #{schema()}.horizon_path_hops (time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_path_hops_target_id
      ON #{schema()}.horizon_path_hops (target_id, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_path_hops_pop_id
      ON #{schema()}.horizon_path_hops (pop_id, time DESC)
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_path_hops_hop_ip
      ON #{schema()}.horizon_path_hops (hop_ip)
      WHERE hop_ip IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_path_hops_asn
      ON #{schema()}.horizon_path_hops (asn)
      WHERE asn IS NOT NULL
    """)

    execute("""
    CREATE INDEX IF NOT EXISTS idx_horizon_path_hops_router_alias_id
      ON #{schema()}.horizon_path_hops (router_alias_id)
      WHERE router_alias_id IS NOT NULL
    """)
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
            AND hypertable_schema = '#{schema()}'
        ) THEN
          EXECUTE format(
            'SELECT %I.create_hypertable(%L::regclass, %L::name, create_default_indexes => false, migrate_data => true, if_not_exists => true)',
            ts_schema,
            '#{schema()}.#{table_name}',
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
