defmodule ServiceRadar.Repo.Migrations.AddIpEnrichmentCacheTables do
  @moduledoc """
  Adds bounded IP enrichment cache tables used by the NetFlow enrichment pipeline.

  These tables are intentionally simple:
  - keyed by `ip` (unique row per IP)
  - enforced TTL via `expires_at`
  - indexed for cheap cleanup + lookup
  """
  use Ecto.Migration

  def up do
    create table(:ip_geo_enrichment_cache, primary_key: false, prefix: "platform") do
      add :ip, :text, primary_key: true, null: false

      # ASN enrichment
      add :asn, :integer
      add :as_org, :text

      # GeoIP enrichment
      add :country_iso2, :text
      add :country_name, :text
      add :region, :text
      add :city, :text
      add :latitude, :float
      add :longitude, :float
      add :timezone, :text

      # Cache control / observability
      add :is_private, :boolean, default: false, null: false
      add :looked_up_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :error, :text
      add :error_count, :integer, default: 0, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ip_geo_enrichment_cache, [:expires_at], prefix: "platform")
    create index(:ip_geo_enrichment_cache, [:asn], prefix: "platform")
    create index(:ip_geo_enrichment_cache, [:country_iso2], prefix: "platform")

    create table(:ip_rdns_cache, primary_key: false, prefix: "platform") do
      add :ip, :text, primary_key: true, null: false

      add :hostname, :text
      add :status, :text

      add :looked_up_at, :utc_datetime_usec, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :error, :text
      add :error_count, :integer, default: 0, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:ip_rdns_cache, [:expires_at], prefix: "platform")
    create index(:ip_rdns_cache, [:hostname], prefix: "platform")
  end

  def down do
    drop index(:ip_rdns_cache, [:hostname], prefix: "platform")
    drop index(:ip_rdns_cache, [:expires_at], prefix: "platform")
    drop table(:ip_rdns_cache, prefix: "platform")

    drop index(:ip_geo_enrichment_cache, [:country_iso2], prefix: "platform")
    drop index(:ip_geo_enrichment_cache, [:asn], prefix: "platform")
    drop index(:ip_geo_enrichment_cache, [:expires_at], prefix: "platform")
    drop table(:ip_geo_enrichment_cache, prefix: "platform")
  end
end

