defmodule ServiceRadar.Inventory.VirtualizationDatastore do
  @moduledoc """
  Provider-neutral virtualization datastore or storage pool inventory.
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
    :storage_type,
    :content,
    :active,
    :enabled,
    :shared,
    :used_bytes,
    :available_bytes,
    :total_bytes,
    :metadata,
    :observed_at
  ]

  postgres do
    table "virtualization_datastores"
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
      allow_nil? false
      public? true
    end

    attribute :storage_type, :string do
      public? true
    end

    attribute :content, :string do
      public? true
    end

    attribute :active, :boolean do
      public? true
    end

    attribute :enabled, :boolean do
      public? true
    end

    attribute :shared, :boolean do
      public? true
    end

    attribute :used_bytes, :integer do
      public? true
    end

    attribute :available_bytes, :integer do
      public? true
    end

    attribute :total_bytes, :integer do
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
