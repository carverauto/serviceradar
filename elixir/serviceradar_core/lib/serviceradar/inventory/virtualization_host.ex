defmodule ServiceRadar.Inventory.VirtualizationHost do
  @moduledoc """
  Provider-neutral hypervisor host inventory linked to canonical devices.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @devices_view_check {ActorHasPermission, permission: "devices.view"}
  @devices_update_check {ActorHasPermission, permission: "devices.update"}
  @devices_delete_check {ActorHasPermission, permission: "devices.delete"}
  @identity_fields [
    :provider,
    :provider_ref,
    :identity_version,
    :identity_state,
    :integration_id,
    :controller_id,
    :native_cluster_id,
    :object_kind,
    :native_object_id,
    :provider_instance_ref
  ]
  @mutable_fields [
    :cluster_id,
    :device_uid,
    :name,
    :status,
    :version,
    :cpu_ratio,
    :memory_used_bytes,
    :memory_total_bytes,
    :uptime_seconds,
    :metadata,
    :observed_at
  ]

  postgres do
    table "virtualization_hosts"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @identity_fields ++ @mutable_fields
    end

    update :update do
      accept @mutable_fields
    end

    read :by_provider_ref do
      argument :provider, :string, allow_nil?: false
      argument :provider_ref, :string, allow_nil?: false
      get? true
      filter expr(provider == ^arg(:provider) and provider_ref == ^arg(:provider_ref))
    end

    read :by_device do
      argument :device_uid, :string, allow_nil?: false
      filter expr(device_uid == ^arg(:device_uid))
    end
  end

  policies do
    import ServiceRadar.Policies

    system_bypass()
    read_with_permission(@devices_view_check)
    action_type_with_permission(:create, @devices_update_check)
    action_type_with_permission(:update, @devices_update_check)
    action_type_with_permission(:destroy, @devices_delete_check)
  end

  attributes do
    uuid_primary_key :id

    attribute :provider, :string do
      allow_nil? false
      public? true
    end

    attribute :provider_ref, :string do
      allow_nil? false
      public? true
    end

    attribute :identity_version, :integer do
      public? true
    end

    attribute :identity_state, :atom do
      allow_nil? false
      default :legacy
      public? true
      constraints one_of: [:legacy, :authoritative, :quarantined]
    end

    attribute :integration_id, :uuid do
      public? true
    end

    attribute :controller_id, :uuid do
      public? true
    end

    attribute :native_cluster_id, :string do
      public? true
    end

    attribute :object_kind, :string do
      public? true
    end

    attribute :native_object_id, :string do
      public? true
    end

    attribute :provider_instance_ref, :string do
      public? true
    end

    attribute :cluster_id, :uuid do
      public? true
    end

    attribute :device_uid, :string do
      public? true
    end

    attribute :name, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :string do
      public? true
    end

    attribute :version, :string do
      public? true
    end

    attribute :cpu_ratio, :float do
      public? true
    end

    attribute :memory_used_bytes, :integer do
      public? true
    end

    attribute :memory_total_bytes, :integer do
      public? true
    end

    attribute :uptime_seconds, :integer do
      public? true
    end

    attribute :metadata, :map do
      allow_nil? false
      default %{}
      public? true
    end

    attribute :observed_at, :utc_datetime_usec do
      public? true
    end

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :cluster, ServiceRadar.Inventory.VirtualizationCluster do
      source_attribute :cluster_id
      allow_nil? true
      public? true
    end

    belongs_to :device, ServiceRadar.Inventory.Device do
      source_attribute :device_uid
      destination_attribute :uid
      allow_nil? true
      public? true
    end

    has_many :guests, ServiceRadar.Inventory.VirtualizationGuest do
      destination_attribute :host_id
      public? true
    end

    has_many :datastores, ServiceRadar.Inventory.VirtualizationDatastore do
      destination_attribute :host_id
      public? true
    end

    has_many :disks, ServiceRadar.Inventory.VirtualizationHostDisk do
      destination_attribute :host_id
      public? true
    end

    has_many :network_interfaces, ServiceRadar.Inventory.VirtualizationNetworkInterface do
      destination_attribute :host_id
      public? true
    end
  end

  identities do
    identity :unique_provider_ref, [:provider, :provider_ref]
  end
end
