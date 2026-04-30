defmodule ServiceRadar.WifiMap.SiteReference do
  @moduledoc "Slowly changing airport/site reference and override rows for WiFi maps."

  use Ash.Resource,
    domain: ServiceRadar.WifiMap,
    data_layer: AshPostgres.DataLayer

  @fields [
    :source_id,
    :site_code,
    :name,
    :site_type,
    :region,
    :latitude,
    :longitude,
    :reference_hash,
    :reference_metadata,
    :updated_at
  ]

  postgres do
    table("wifi_site_references")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept(@fields)
      upsert?(true)
      upsert_identity(:source_site)
      upsert_fields(@fields)
    end
  end

  attributes do
    attribute :source_id, :uuid do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
    end

    attribute :site_code, :string do
      primary_key?(true)
      allow_nil?(false)
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :site_type, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :region, :string do
      public?(true)
    end

    attribute :latitude, :float do
      constraints(min: -90.0, max: 90.0)
      public?(true)
    end

    attribute :longitude, :float do
      constraints(min: -180.0, max: 180.0)
      public?(true)
    end

    attribute :reference_hash, :string do
      public?(true)
    end

    attribute :reference_metadata, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    attribute :updated_at, :utc_datetime_usec do
      allow_nil?(false)
      public?(true)
    end
  end

  identities do
    identity(:source_site, [:source_id, :site_code])
  end
end
