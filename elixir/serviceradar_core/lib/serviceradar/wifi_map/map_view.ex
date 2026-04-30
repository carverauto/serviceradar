defmodule ServiceRadar.WifiMap.MapView do
  @moduledoc "Saved SRQL-backed WiFi map view configuration."

  use Ash.Resource,
    domain: ServiceRadar.WifiMap,
    data_layer: AshPostgres.DataLayer

  @fields [
    :name,
    :description,
    :srql_query,
    :is_default_dashboard,
    :visualization_options
  ]

  postgres do
    table("wifi_map_views")
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
    uuid_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :description, :string do
      public?(true)
    end

    attribute :srql_query, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :is_default_dashboard, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    attribute :visualization_options, :map do
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
