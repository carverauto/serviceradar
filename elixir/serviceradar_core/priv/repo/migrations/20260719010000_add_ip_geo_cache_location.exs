defmodule ServiceRadar.Repo.Migrations.AddIpGeoCacheLocation do
  @moduledoc """
  Adds a PostGIS geography point on `platform.ip_geo_enrichment_cache` for
  proximity queries used by SRQL flow filters (`near:`).

  Follows the FieldSurvey/WiFi-map pattern: generated column from
  longitude/latitude + partial GiST index. Writers keep setting lat/lng only;
  the location is maintained by Postgres.
  """

  use Ecto.Migration

  def up do
    execute("CREATE EXTENSION IF NOT EXISTS postgis;")

    execute("""
    ALTER TABLE platform.ip_geo_enrichment_cache
    ADD COLUMN IF NOT EXISTS location geography(Point, 4326)
    GENERATED ALWAYS AS (
      CASE
        WHEN latitude IS NOT NULL
         AND longitude IS NOT NULL
         AND latitude BETWEEN -90 AND 90
         AND longitude BETWEEN -180 AND 180
        THEN ST_SetSRID(ST_MakePoint(longitude, latitude), 4326)::geography
        ELSE NULL
      END
    ) STORED
    """)

    # Partial GiST: only rows with coordinates participate in proximity scans.
    execute("""
    CREATE INDEX IF NOT EXISTS ip_geo_enrichment_cache_location_gist_idx
      ON platform.ip_geo_enrichment_cache
      USING gist (location)
      WHERE location IS NOT NULL
    """)
  end

  def down do
    execute("DROP INDEX IF EXISTS platform.ip_geo_enrichment_cache_location_gist_idx")
    execute("ALTER TABLE platform.ip_geo_enrichment_cache DROP COLUMN IF EXISTS location")
  end
end
