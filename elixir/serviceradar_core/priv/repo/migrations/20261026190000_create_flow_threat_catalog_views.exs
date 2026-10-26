defmodule ServiceRadar.Repo.Migrations.CreateFlowThreatCatalogViews do
  @moduledoc """
  Lets StarRocks 4.1 answer the flow `threat_source`, `threat_indicator` and
  `near` filters through the plain `cnpg_platform` JDBC catalog.

  StarRocks 4.1 has no JDBC pass-through (`native_query` first ships in 4.2),
  and its JDBC catalog cannot read PostgreSQL `text[]`, `cidr` or `geography`
  columns. These `_catalog` views flatten what the filters need into scalar
  columns:

    * `ip_threat_intel_sources_catalog` has one row per cache IP and feed
      source (the cache's `sources` array, unnested). `threat_source:` selects
      `source IN (...)`.
    * `threat_intel_indicator_members_catalog` has one row per cache IP and
      indicator that contains it, joined with PostgreSQL's own `<<=`. It
      carries the indicator text, its address family, and its first and last
      address as fixed-width hex, encoded like `netflow_local_cidrs_catalog`.
      `threat_indicator:` compares those hex bounds the way SRQL's `cidr:`
      filter does.

  Both views hold only current matches: matched cache rows that have not
  expired, and for memberships, indicators that have not expired either. The
  cache and indicator timestamps are UTC without a time zone, so `now()` is
  taken at UTC. Whoever reads a view, and whatever predicates reach it, the
  containment join only ever expands live matches. SRQL still repeats those
  conditions in the query it sends, which keeps the result the same if a view
  is ever widened.

  `near:` reads `latitude` and `longitude` from `ip_geo_enrichment_cache`, so
  the reader gains those two columns. A view would not help there: the center
  point is chosen at query time.

  Plain views over current-state tables: no backfill, no rewrite, and only
  brief catalog locks, bounded by the lock timeout. Grants are guarded on the
  reader role existing; the chart's catalog-reader Job repeats them when the
  catalog is enabled after this migration. Login remains CNPG-managed.
  """

  use Ecto.Migration

  @role "serviceradar_starrocks_reader"
  @grants [
    {"ip_threat_intel_sources_catalog", "ip, matched, expires_at, source"},
    {"threat_intel_indicator_members_catalog",
     "ip, matched, expires_at, indicator, indicator_family, first_ip_hex, last_ip_hex, indicator_expires_at"},
    {"ip_geo_enrichment_cache", "latitude, longitude"}
  ]

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    CREATE OR REPLACE VIEW platform.ip_threat_intel_sources_catalog AS
    SELECT c.ip, c.matched, c.expires_at, s.source
    FROM platform.ip_threat_intel_cache c
    CROSS JOIN LATERAL unnest(c.sources) AS s(source)
    WHERE c.matched AND c.expires_at > (now() AT TIME ZONE 'utc')
    """)

    execute("""
    CREATE OR REPLACE VIEW platform.threat_intel_indicator_members_catalog AS
    SELECT c.ip, c.matched, c.expires_at,
           i.indicator::text AS indicator,
           family(i.indicator) AS indicator_family,
           substring(encode(inet_send(network(i.indicator)::inet), 'hex') from 9) AS first_ip_hex,
           substring(encode(inet_send(broadcast(i.indicator)), 'hex') from 9) AS last_ip_hex,
           i.expires_at AS indicator_expires_at
    FROM platform.ip_threat_intel_cache c
    JOIN platform.threat_intel_indicators i ON c.ip::inet <<= i.indicator
    WHERE c.matched AND c.expires_at > (now() AT TIME ZONE 'utc')
      AND (i.expires_at IS NULL OR i.expires_at > (now() AT TIME ZONE 'utc'))
    """)

    for {relation, columns} <- @grants do
      execute("""
      DO $$
      BEGIN
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
          GRANT SELECT (#{columns}) ON platform.#{relation} TO #{@role};
        END IF;
      END $$;
      """)
    end
  end

  def down do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '#{@role}') THEN
        REVOKE SELECT (latitude, longitude) ON platform.ip_geo_enrichment_cache FROM #{@role};
      END IF;
    END $$;
    """)

    execute("DROP VIEW IF EXISTS platform.threat_intel_indicator_members_catalog")
    execute("DROP VIEW IF EXISTS platform.ip_threat_intel_sources_catalog")
  end
end
