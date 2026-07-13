defmodule ServiceRadar.Inventory.DeviceSourceSnapshot do
  @moduledoc "Current activated complete snapshot for one inventory source instance."

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_source_snapshots"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read]
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    uuid_primary_key :id
    attribute :partition, :string, allow_nil?: false, default: "default", public?: true
    attribute :source, :string, allow_nil?: false, public?: true
    attribute :source_instance, :string, allow_nil?: false, public?: true
    attribute :collection_id, :string, allow_nil?: false, public?: true
    attribute :content_hash, :string, allow_nil?: false, public?: true
    attribute :query_hash, :string, public?: true
    attribute :observed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :activated_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :device_count, :integer, allow_nil?: false, default: 0, public?: true
    attribute :absent_count, :integer, allow_nil?: false, default: 0, public?: true

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :unique_source_instance, [:partition, :source, :source_instance]
  end
end
