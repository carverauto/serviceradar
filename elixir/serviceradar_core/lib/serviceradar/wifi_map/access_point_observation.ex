defmodule ServiceRadar.WifiMap.AccessPointObservation do
  @moduledoc "WiFi access point observation linked to canonical device identity when available."

  use Ash.Resource,
    domain: ServiceRadar.WifiMap,
    data_layer: AshPostgres.DataLayer

  @fields [
    :source_id,
    :batch_id,
    :device_uid,
    :site_code,
    :collection_timestamp,
    :name,
    :hostname,
    :mac,
    :serial,
    :ip,
    :status,
    :model,
    :vendor_name,
    :metadata
  ]

  postgres do
    table("wifi_access_point_observations")
    repo(ServiceRadar.Repo)
    schema("platform")
    migrate?(false)
  end

  actions do
    defaults([:read, :destroy])

    create :upsert do
      accept(@fields)
      upsert?(true)
      upsert_identity(:source_time_name)
      upsert_fields(@fields ++ [:updated_at])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:source_id, :uuid, allow_nil?: false, public?: true)
    attribute(:batch_id, :uuid, public?: true)
    attribute(:device_uid, :string, public?: true)
    attribute(:site_code, :string, allow_nil?: false, public?: true)
    attribute(:collection_timestamp, :utc_datetime_usec, allow_nil?: false, public?: true)
    attribute(:name, :string, public?: true)
    attribute(:hostname, :string, public?: true)
    attribute(:mac, :string, public?: true)
    attribute(:serial, :string, public?: true)
    attribute(:ip, :string, public?: true)
    attribute(:status, :string, public?: true)
    attribute(:model, :string, public?: true)
    attribute(:vendor_name, :string, public?: true)
    attribute(:metadata, :map, allow_nil?: false, default: %{}, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  identities do
    identity(:source_time_name, [:source_id, :collection_timestamp, :name])
  end
end
