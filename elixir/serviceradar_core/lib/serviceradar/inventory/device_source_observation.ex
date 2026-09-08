defmodule ServiceRadar.Inventory.DeviceSourceObservation do
  @moduledoc """
  Current and historical-presence state for one source-owned device object.

  Canonical device identity remains in `ocsf_devices`; this resource records
  which external object observed that canonical device and in which complete
  collection it was last present.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_source_observations"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_id]
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :device_id, :string, allow_nil?: false
      filter expr(device_id == ^arg(:device_id))
      prepare build(sort: [present: :desc, last_observed_at: :desc])
    end

    update :reassign_device do
      accept [:device_id]
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
    operator_action(:reassign_device)
  end

  attributes do
    uuid_primary_key :id

    attribute :device_id, :string, allow_nil?: false, public?: true
    attribute :partition, :string, allow_nil?: false, default: "default", public?: true
    attribute :source, :string, allow_nil?: false, public?: true
    attribute :source_instance, :string, allow_nil?: false, public?: true
    attribute :source_object_id, :string, allow_nil?: false, public?: true
    attribute :source_integration_id, :string, allow_nil?: false, public?: true
    attribute :collection_id, :string, allow_nil?: false, public?: true
    attribute :content_hash, :string, allow_nil?: false, public?: true
    attribute :query_hash, :string, public?: true
    attribute :present, :boolean, allow_nil?: false, default: true, public?: true
    attribute :first_observed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :last_observed_at, :utc_datetime_usec, allow_nil?: false, public?: true
    attribute :absent_since, :utc_datetime_usec, public?: true
    attribute :hostname, :string, public?: true
    attribute :ip, :string, public?: true
    attribute :mac, :string, public?: true
    attribute :serial_number, :string, public?: true
    attribute :vendor_name, :string, public?: true
    attribute :model, :string, public?: true
    attribute :device_type, :string, public?: true
    attribute :site_name, :string, public?: true
    attribute :management_status, :string, public?: true

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  relationships do
    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_id
      destination_attribute :uid
      define_attribute? false
      allow_nil? false
      public? true
    end
  end

  identities do
    identity :unique_source_object, [:partition, :source, :source_instance, :source_object_id]
  end
end
