defmodule ServiceRadar.Inventory.DeviceSourceFact do
  @moduledoc """
  Normalized inventory fact reported by one source for one canonical device.

  Canonical `ocsf_devices` fields are filled from these rows by
  `ServiceRadar.Inventory.SourceFacts.Reconciler`. Source-prefixed metadata
  on the device is left intact.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  postgres do
    table "device_source_facts"
    repo ServiceRadar.Repo
    schema "platform"
  end

  code_interface do
    define :list_by_device, action: :by_device, args: [:device_uid]
  end

  actions do
    defaults [:read]

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
      prepare build(sort: [present: :desc, observed_at: :desc])
    end

    read :present_for_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid) and present == true)
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_viewer_plus()
  end

  attributes do
    uuid_primary_key :id

    attribute :device_uid, :string, allow_nil?: false, public?: true
    attribute :source, :string, allow_nil?: false, public?: true
    attribute :source_instance, :string, allow_nil?: false, default: "default", public?: true
    attribute :fact_key, :string, allow_nil?: false, public?: true
    attribute :compare_hash, :string, allow_nil?: false, public?: true

    attribute :value, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :raw, :string, public?: true
    attribute :present, :boolean, allow_nil?: false, default: true, public?: true
    attribute :observed_at, :utc_datetime_usec, allow_nil?: false, public?: true

    create_timestamp :inserted_at, type: :utc_datetime_usec
    update_timestamp :updated_at, type: :utc_datetime_usec
  end

  identities do
    identity :unique_device_source_fact, [:device_uid, :source, :source_instance, :fact_key]
  end
end
