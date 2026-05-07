defmodule ServiceRadar.Inventory.VirtualizationStorageSystem do
  @moduledoc """
  Provider-neutral clustered storage health attached to virtualization inventory.
  """

  use Ash.Resource,
    domain: ServiceRadar.Inventory,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  alias ServiceRadar.Policies.Checks.ActorHasPermission

  @devices_view_check {ActorHasPermission, permission: "devices.view"}
  @devices_update_check {ActorHasPermission, permission: "devices.update"}
  @devices_delete_check {ActorHasPermission, permission: "devices.delete"}
  @fields [
    :provider,
    :provider_ref,
    :cluster_id,
    :host_id,
    :name,
    :storage_system_type,
    :health,
    :status,
    :metadata,
    :observed_at
  ]

  postgres do
    table "virtualization_storage_systems"
    repo ServiceRadar.Repo
    schema "platform"
  end

  actions do
    defaults [:read, :destroy]

    create :create do
      accept @fields
    end

    update :update do
      accept @fields
    end

    read :by_provider_ref do
      argument :provider, :string, allow_nil?: false
      argument :provider_ref, :string, allow_nil?: false
      get? true
      filter expr(provider == ^arg(:provider) and provider_ref == ^arg(:provider_ref))
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

    attribute :cluster_id, :uuid do
      public? true
    end

    attribute :host_id, :uuid do
      public? true
    end

    attribute :name, :string do
      public? true
    end

    attribute :storage_system_type, :string do
      allow_nil? false
      public? true
    end

    attribute :health, :string do
      public? true
    end

    attribute :status, :string do
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

    belongs_to :host, ServiceRadar.Inventory.VirtualizationHost do
      source_attribute :host_id
      allow_nil? true
      public? true
    end
  end

  identities do
    identity :unique_provider_ref, [:provider, :provider_ref]
  end
end
