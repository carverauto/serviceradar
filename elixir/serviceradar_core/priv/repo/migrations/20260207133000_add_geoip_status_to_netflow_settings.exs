defmodule ServiceRadar.Repo.Migrations.AddGeoipStatusToNetflowSettings do
  @moduledoc """
  Adds persisted GeoIP enrichment status fields to NetFlow settings.

  These fields exist to support admin UX (last refresh timestamps/errors) without
  requiring operators to scrape logs.

  All objects live in the `platform` schema.
  """

  use Ecto.Migration

  def up do
    alter table(:netflow_settings, prefix: "platform") do
      add :geoip_enabled, :boolean, null: false, default: true

      add :geolite_mmdb_last_attempt_at, :utc_datetime_usec
      add :geolite_mmdb_last_success_at, :utc_datetime_usec
      add :geolite_mmdb_last_error, :text

      add :ip_enrichment_last_attempt_at, :utc_datetime_usec
      add :ip_enrichment_last_success_at, :utc_datetime_usec
      add :ip_enrichment_last_error, :text
    end
  end

  def down do
    alter table(:netflow_settings, prefix: "platform") do
      remove :ip_enrichment_last_error
      remove :ip_enrichment_last_success_at
      remove :ip_enrichment_last_attempt_at

      remove :geolite_mmdb_last_error
      remove :geolite_mmdb_last_success_at
      remove :geolite_mmdb_last_attempt_at

      remove :geoip_enabled
    end
  end
end
