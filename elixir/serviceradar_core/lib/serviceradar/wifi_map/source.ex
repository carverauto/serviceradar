defmodule ServiceRadar.WifiMap.Source do
  @moduledoc "Configured source state for WiFi-map ingestion."

  use Ash.Resource,
    domain: ServiceRadar.WifiMap,
    data_layer: AshPostgres.DataLayer

  @fields [
    :plugin_source_id,
    :name,
    :source_kind,
    :latest_collection_at,
    :latest_reference_hash,
    :latest_reference_at,
    :metadata
  ]

  postgres do
    table("wifi_map_sources")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept(@fields)
      upsert?(true)
      upsert_identity(:unique_name)
      upsert_fields(@fields ++ [:updated_at])
    end
  end

  attributes do
    uuid_primary_key(:id, source: :source_id)

    attribute :plugin_source_id, :uuid do
      public?(true)
    end

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :source_kind, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :latest_collection_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :latest_reference_hash, :string do
      public?(true)
    end

    attribute :latest_reference_at, :utc_datetime_usec do
      public?(true)
    end

    attribute :metadata, :map do
      allow_nil?(false)
      default(%{})
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:unique_name, [:name])
  end
end
